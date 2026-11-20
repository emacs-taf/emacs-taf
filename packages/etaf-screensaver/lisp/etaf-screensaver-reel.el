;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-reel.el --- Adapting recorded frame sequences

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A reel is a recorded animation from an external animation tool, shown
;; through the ordinary scene contract.  Providers translate one native
;; format into frames; the reel layer owns pacing, center fitting and the
;; lazy conversion shared by every provider.  Recording bytes stay in their
;; native format: importing references and copies them, it does not
;; transcode them.  Registration retains metadata only.  Built-in image
;; bundles can validate the next queued page incrementally during playback;
;; other providers are read when their scene is created.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-ansi)
(require 'etaf-screensaver-glyphs)
(defvar etaf-screensaver-reel-text-scale)
(declare-function image-size "image.c" (spec &optional pixels frame))

(defvar etaf-screensaver--reel-directory nil
  "Directory of the reel file being read, used to resolve :recording.")

(defconst etaf-screensaver--reel-provider-keys
  '(:title :license :extensions :match :read)
  "Keys accepted in a reel provider description.
:TITLE and :LICENSE are display strings.  :EXTENSIONS lists file name
suffixes without a leading dot for batch import.  :MATCH takes a file path
and returns non-nil when the provider recognizes it.  :READ takes a file
path and returns a plist with :frame-rate (positive number), :frames (a
nonempty vector of text frame strings) or :image-frames (a nonempty vector
of image file names), :width and :height (positive cell dimensions, text
frames) or :image-size (a (WIDTH . HEIGHT) pixel pair, optional for image
frames), optional :image-types (same-length vector of format symbols, otherwise
lazily detected), plus optional :durations (seconds per frame), :ansi
(frame text carries SGR runs), :source (a short display description), :license (the
recording's own licence), :assets (every file that belongs to the
recording, for import) and :colors/:attributes.")

(defvar etaf-screensaver--reel-providers nil
  "Registered reel providers as (ID . PLIST) pairs.")

(defun etaf-screensaver-define-reel-provider (id &rest properties)
  "Register the reel provider ID with PROPERTIES and return ID.
PROPERTIES is a plist with :title, :license, :extensions, :match and :read;
see `etaf-screensaver--reel-provider-keys' for their meaning.  Re-registering
an ID replaces the provider in place, so a provider can be refined without
disturbing imported reels."
  (unless (symbolp id)
    (etaf-screensaver--fail "Reel provider must be a symbol: %S" id))
  (let ((plist properties))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--reel-provider-keys)
          (etaf-screensaver--fail "Reel provider %s has unknown key %S" id key)))))
  (let ((title (plist-get properties :title))
        (license (plist-get properties :license))
        (extensions (plist-get properties :extensions)))
    (unless (and (stringp title) (not (equal title "")))
      (etaf-screensaver--fail "Reel provider %s needs a nonempty :title" id))
    (unless (and (stringp license) (not (equal license "")))
      (etaf-screensaver--fail "Reel provider %s needs a nonempty :license" id))
    (unless (and (proper-list-p extensions)
                 (cl-every (lambda (extension)
                             (and (stringp extension) (not (equal extension ""))))
                           extensions))
      (etaf-screensaver--fail "Reel provider %s :extensions must be file name suffixes" id))
    (dolist (key '(:match :read))
      (unless (functionp (plist-get properties key))
        (etaf-screensaver--fail "Reel provider %s needs a function for %s" id key))))
  (setf etaf-screensaver--reel-providers
        (cons (cons id properties)
              (assq-delete-all id etaf-screensaver--reel-providers)))
  id)

(defconst etaf-screensaver--reel-keys
  '(:id :title :summary :tags :provider :recording :kind :width :height :frame-rate
    :duration :frame-count :source :license :background)
  "Keys accepted in a reel spec.")

(defconst etaf-screensaver--reel-read-cache-limit 32
  "Maximum recent recordings retained for replay, subject to a shared budget.")

(defconst etaf-screensaver--reel-read-cache-bytes (* 48 1024 1024)
  "Combined frame-text and image-path byte budget of the read cache.")

(defvar etaf-screensaver--reel-read-cache nil
  "Recent provider reads as (KEY SIZE DATA) entries, most recently used first.
KEY identifies the provider, file and its size and modification time, so an
edited recording is read again.  SIZE counts frame-text and image-path bytes,
not decoded images.  The shared budget bounds their aggregate retention.")

(defun etaf-screensaver--reel-read-cache-key (provider-id file)
  "Return the read-cache key of FILE read through PROVIDER-ID."
  (let ((attributes (file-attributes file)))
    (list provider-id (file-truename file)
          (file-attribute-size attributes)
          (float-time (file-attribute-modification-time attributes)))))

(defun etaf-screensaver--reel-data-size (data)
  "Return DATA's frame-text and image-path payload size in bytes."
  (let ((total 0))
    (dolist (key '(:frames :image-frames))
      (let ((frames (plist-get data key)))
        (when (vectorp frames)
          (dotimes (index (length frames))
            (cl-incf total (string-bytes (aref frames index)))))))
    total))

(defun etaf-screensaver--reel-cache-put (key data)
  "Admit validated DATA under KEY within the shared read-cache budget."
  (let ((size (etaf-screensaver--reel-data-size data)))
    (when (<= size etaf-screensaver--reel-read-cache-bytes)
      (let ((remaining etaf-screensaver--reel-read-cache-bytes)
            (count 0) kept)
        (dolist (entry (cons (list key size data)
                            (assoc-delete-all key etaf-screensaver--reel-read-cache)))
          (when (and (< count etaf-screensaver--reel-read-cache-limit)
                     (<= (nth 1 entry) remaining))
            (cl-incf count)
            (cl-decf remaining (nth 1 entry))
            (push entry kept)))
        (setq etaf-screensaver--reel-read-cache (nreverse kept)))))
  data)

(defun etaf-screensaver--reel-read (provider-id provider file)
  "Read FILE through PROVIDER, reusing a recent unchanged result.
Read errors are not cached.  Recent recordings share one payload budget;
image manifests retain paths only, never decoded frames."
  (let* ((key (etaf-screensaver--reel-read-cache-key provider-id file))
         (cached (assoc key etaf-screensaver--reel-read-cache)))
    (if cached
        (progn
          (setq etaf-screensaver--reel-read-cache
                (cons cached (delq cached etaf-screensaver--reel-read-cache)))
          (nth 2 cached))
      (etaf-screensaver--reel-cache-put key (funcall (plist-get provider :read) file)))))

(defun etaf-screensaver--reel-file (recording)
  "Return RECORDING as an absolute file name.
A relative RECORDING resolves against the reel file's directory, or the
current `default-directory' when a reel is registered from Lisp."
  (if (file-name-absolute-p recording)
      recording
    (expand-file-name recording (or etaf-screensaver--reel-directory
                                    default-directory))))

(defun etaf-screensaver--reel-validate (spec)
  "Validate reel spec SPEC and return it.
Signal `etaf-screensaver-error' for unknown keys or invalid values."
  (unless (proper-list-p spec)
    (etaf-screensaver--fail "Reel spec must be a plist: %S" spec))
  (let ((plist spec))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--reel-keys)
          (etaf-screensaver--fail "Reel spec has unknown key %S" key)))))
  (let ((id (plist-get spec :id))
        (title (plist-get spec :title))
        (summary (plist-get spec :summary))
        (tags (plist-get spec :tags))
        (provider (plist-get spec :provider))
        (recording (plist-get spec :recording))
        (kind (plist-get spec :kind))
        (width (plist-get spec :width))
        (height (plist-get spec :height))
        (frame-rate (plist-get spec :frame-rate))
        (duration (plist-get spec :duration))
        (frame-count (plist-get spec :frame-count))
        (source (plist-get spec :source))
        (license (plist-get spec :license))
        (background (plist-get spec :background)))
    (unless (symbolp id)
      (etaf-screensaver--fail "Reel spec needs a symbol :id: %S" id))
    (unless (and (symbolp provider) provider)
      (etaf-screensaver--fail "Reel %s needs a :provider symbol" id))
    (unless (cdr (assq provider etaf-screensaver--reel-providers))
      (etaf-screensaver--fail "Reel %s uses an unknown provider: %s" id provider))
    (unless (and (stringp recording) (not (equal recording "")))
      (etaf-screensaver--fail "Reel %s needs a nonempty :recording file name" id))
    (unless (or (null kind) (memq kind '(text image)))
      (etaf-screensaver--fail "Reel %s :kind must be text or image" id))
    (unless (or (null title) (and (stringp title) (not (equal title ""))))
      (etaf-screensaver--fail "Reel %s :title must be a nonempty string" id))
    (unless (or (null summary) (stringp summary))
      (etaf-screensaver--fail "Reel %s :summary must be a string" id))
    (unless (or (null tags) (proper-list-p tags))
      (etaf-screensaver--fail "Reel %s :tags must be a list" id))
    (dolist (entry (list (cons :width width) (cons :height height)
                         (cons :frame-count frame-count)))
      (let ((value (cdr entry)))
        (unless (or (null value)
                    (and (integerp value) (>= value 1)
                         (if (eq (car entry) :frame-count)
                             t
                           (<= value 4096))))
          (etaf-screensaver--fail "Reel %s %s must be a positive integer" id (car entry)))))
    (unless (or (null frame-rate) (and (numberp frame-rate) (> frame-rate 0)))
      (etaf-screensaver--fail "Reel %s :frame-rate must be a positive number" id))
    (unless (or (null duration) (and (numberp duration) (> duration 0)))
      (etaf-screensaver--fail "Reel %s :duration must be a positive number" id))
    (unless (or (null source) (stringp source))
      (etaf-screensaver--fail "Reel %s :source must be a string" id))
    (unless (or (null license) (stringp license))
      (etaf-screensaver--fail "Reel %s :license must be a string" id))
    (unless (or (null background) (stringp background))
      (etaf-screensaver--fail "Reel %s :background must be a color string" id)))
  spec)

(defconst etaf-screensaver--reel-continuation 'continuation
  "Cell marker for the second display cell of a wide character.")

(defun etaf-screensaver--reel-entry (state index)
  "Return INDEX's cached (ROWS . CELLS) entry of STATE, converting it once."
  (let* ((cache (plist-get state :cache))
         (entry (aref cache index)))
    (unless entry
      (let* ((frame (aref (plist-get state :frames) index))
             (text (if (plist-get state :ansi)
                       (etaf-screensaver--ansi-render frame)
                     frame))
             (rows (vconcat (split-string text "\n"))))
        (unless (= (length rows) (plist-get state :height))
          (etaf-screensaver--fail "Reel frame %d has %d rows, expected %d"
                                  index (length rows) (plist-get state :height)))
        (setq entry (cons rows nil))
        (aset cache index entry)))
    entry))

(defun etaf-screensaver--reel-cells (entry)
  "Return ENTRY's rows expanded to one (CHARACTER . FACE) per display cell.
The second cell of a wide character holds `etaf-screensaver--reel-continuation'."
  (or (cdr entry)
      (setcdr entry
              (vconcat
               (mapcar
                (lambda (row)
                  (let ((cells nil) (index 0))
                    (while (< index (length row))
                      (let* ((character (aref row index))
                             (width (char-width character))
                             (face (get-text-property index 'face row)))
                        (push (cons character face) cells)
                        (dotimes (_ (1- width))
                          (push (cons etaf-screensaver--reel-continuation face) cells))
                        (cl-incf index)))
                    (vconcat (nreverse cells))))
                (car entry))))))

(defun etaf-screensaver--reel-run (run face)
  "Return the characters collected in RUN with FACE applied."
  (let ((text (apply #'concat (nreverse run))))
    (if face (propertize text 'face face) text)))

(defun etaf-screensaver--reel-slice (cells start width)
  "Return display cells START..START+WIDTH-1 of CELLS as one propertized string.
A window edge that splits a wide character shows a space for the excluded
half, so the result always occupies exactly WIDTH display cells."
  (let ((end (min (length cells) (+ start width)))
        (index start)
        (parts nil)
        (run nil)
        (run-face :unset))
    (cl-labels
        ((emit (character face)
           (if (and run (equal face run-face))
               (push (string character) run)
             (when run
               (push (etaf-screensaver--reel-run run run-face) parts))
             (setq run (list (string character))
                   run-face face))))
      (while (< index end)
        (let ((character (car (aref cells index)))
              (face (cdr (aref cells index))))
          (if (eq character etaf-screensaver--reel-continuation)
              (progn (emit ?\s face) (cl-incf index))
            (let ((size (char-width character)))
              (if (<= (+ index size) end)
                  (progn (emit character face) (cl-incf index size))
                (emit ?\s face)
                (cl-incf index))))))
      (when run
        (push (etaf-screensaver--reel-run run run-face) parts))
      (apply #'concat (nreverse parts)))))

(defun etaf-screensaver--reel-image-size (state index)
  "Return image frame INDEX's native pixel size from STATE.
The provider may declare :image-size for a uniform recording; otherwise the
size is read from the first frame that needs it and cached."
  (or (plist-get state :image-size)
      (aref (plist-get state :image-sizes) index)
      (let* ((file (aref (plist-get state :image-frames) index))
             (spec (condition-case nil (create-image file nil nil) (error nil)))
             (size (and spec (ignore-errors (image-size spec t)))))
        (unless (and (consp size) (integerp (car size)) (integerp (cdr size))
                     (> (car size) 0) (> (cdr size) 0))
          (etaf-screensaver--fail "Reel image frame is not readable: %s" file))
        (aset (plist-get state :image-sizes) index size)
        size)))

(defun etaf-screensaver--reel-image-type (state index)
  "Return STATE's image format at INDEX, detecting it once if not supplied."
  (or (aref (plist-get state :image-types) index)
      (let* ((file (aref (plist-get state :image-frames) index))
             (type (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally file nil 0 8192)
                     (image-type-from-data (buffer-string)))))
        (unless type
          (etaf-screensaver--fail "Reel image format is not recognized: %s" file))
        (aset (plist-get state :image-types) index type)
        type)))

(cl-defstruct (etaf-screensaver--reel-image-layout
               (:constructor etaf-screensaver--reel-image-layout-new))
  key properties rows runs start end)

(defun etaf-screensaver--reel-image-layout-create (key)
  "Build reusable logical rows and read-only slice geometry for KEY."
  (cl-destructuring-bind (source-width source-height columns rows char-width line-height ascent) key
    (let* ((canvas-width (* columns char-width))
           (canvas-height (* rows line-height))
           ;; Preserve native pixels whenever the work fits.  Upscaling or
           ;; rounding a fitting image to whole lines blurs the source.
           (fit (min 1.0 (/ (float canvas-width) source-width)
                     (/ (float canvas-height) source-height)))
           (height (max 1 (floor (* source-height fit))))
           (scale (/ (float height) source-height))
           (width (max char-width (round (* source-width scale))))
           (offset-x (max 0 (/ (- canvas-width width) 2)))
           (offset-y (* line-height (max 0 (/ (- rows (ceiling height line-height)) 2))))
           (pad (min (1- columns) (max 0 (/ offset-x char-width))))
           (span (min (- columns pad) (max 1 (ceiling width char-width))))
           (slack (- (* span char-width) width))
           (spacer (and (> span 1) (> slack 0)))
           (end (+ pad (if spacer (1- span) span)))
           lines runs)
      (dotimes (row rows)
        (let ((text (make-string columns ?\s))
              (y (- (* row line-height) offset-y)))
          (when (and (>= y 0) (< y height))
            (let* ((slice-height (min line-height (- height y)))
                   ;; A partial final slice must keep the full slice's top
                   ;; alignment.  Cache this geometry, not per-frame math.
                   (raise (/ (- (floor (* line-height ascent) 100)
                                (floor (* slice-height ascent) 100))
                             (float line-height))))
              (push (list text (list 'slice 0 y width slice-height) raise) runs))
            ;; Reserve the exact cell footprint without stretching the image:
            ;; the last cell supplies its fractional-column rounding slack.
            (when spacer
              (put-text-property end (1+ end) 'display
                                 (list 'space :width (list slack)) text)))
          (push text lines)))
      (etaf-screensaver--reel-image-layout-new
       :key key :properties (list :scale scale :max-width width :max-height height :ascent ascent)
       :rows (nreverse lines) :runs (nreverse runs) :start pad :end end))))

(defun etaf-screensaver--reel-image-rows (state context)
  "Return STATE's current image frame as centered canvas rows.
Reuse only the current geometry's logical text, including both margins.
Each frame replaces display values, never mutating a descriptor or slice
already shared with a published row or frozen outgoing page."
  (let* ((index (plist-get state :index))
         (file (aref (plist-get state :image-frames) index))
         (native (etaf-screensaver--reel-image-size state index))
         (metrics (plist-get context :metrics))
         (key (list (max 1 (car native)) (max 1 (cdr native))
                    (max 1 (plist-get context :columns)) (max 1 (plist-get context :rows))
                    (max 1 (or (plist-get metrics :char-width) (frame-char-width)))
                    (max 1 (or (plist-get metrics :line-height) (frame-char-height)))
                    (or (plist-get metrics :ascent) 82)))
         (layout (plist-get state :image-layout)))
    (unless (and layout (equal key (etaf-screensaver--reel-image-layout-key layout)))
      (setq layout (etaf-screensaver--reel-image-layout-create key))
      (setf (plist-get state :image-layout) layout))
    (let* ((type (etaf-screensaver--reel-image-type state index))
           (properties (etaf-screensaver--reel-image-layout-properties layout))
           (image
            (if (image-type-available-p type)
                (apply #'create-image file type nil properties)
              (if (display-graphic-p)
                  (etaf-screensaver--fail "No image decoder for %s: %s" type file)
                ;; Headless publication retains a normal descriptor without
                ;; decoding pixels; the public buffer remains testable.
                (append (list 'image :type type :file file) properties)))))
      (dolist (run (etaf-screensaver--reel-image-layout-runs layout))
        (let* ((slice (nth 1 run))
               (raise (nth 2 run))
               (display (if (zerop raise) (list slice image)
                          (list slice image (list 'raise raise)))))
          (put-text-property (etaf-screensaver--reel-image-layout-start layout)
                             (etaf-screensaver--reel-image-layout-end layout)
                             'display display (car run)))))
    (etaf-screensaver--reel-image-layout-rows layout)))

(defun etaf-screensaver--reel-text-focus (state)
  "Return STATE's subject bounds from its last visible frame.
A baked loop may close on a blank frame.  The settled subject is still the
last frame that contains text before that close, not the blank frame."
  (or (plist-get state :text-focus)
      (let ((index (1- (length (plist-get state :frames)))) focus)
        (while (and (>= index 0)
                    (null (setq focus
                                (etaf-screensaver--glyph-focus
                                 (car (etaf-screensaver--reel-entry state index))))))
          (cl-decf index))
        (if (>= index 0)
            (progn
              (setf (plist-get state :text-focus) focus
                    (plist-get state :text-focus-index) index)
              focus)
          (setf (plist-get state :text-focus) 'empty)))))

(defun etaf-screensaver--reel-text-rows (state context)
  "Render recorded text at its snapshotted scale, keeping native TTY output."
  (or
   (when (and (not (eq (plist-get state :text-scale) 1))
              (display-graphic-p) (image-type-available-p 'svg))
     (let* ((focus (etaf-screensaver--reel-text-focus state))
            (final (car (etaf-screensaver--reel-entry
                         state (or (plist-get state :text-focus-index)
                                   (1- (length (plist-get state :frames)))))))
            (subject (unless (eq focus 'empty)
                       (or (plist-get state :glyph-subject)
                           ;; Cache in place: the key exists from creation,
                           ;; so this mutates the state instead of a copy.
                           (setf (plist-get state :glyph-subject)
                                 (etaf-screensaver--glyph-subject final focus)))))
            (columns (plist-get context :columns)) (rows (plist-get context :rows))
            (policy (plist-get state :text-scale))
            (scale (if (eq focus 'empty) 1
                     (max 1 (min (/ rows (- (nth 3 focus) (nth 1 focus)))
                                 (/ columns (- (nth 2 focus) (nth 0 focus)))
                                 (if (eq policy 'auto)
                                     (floor (min 24 (/ (* columns .95) (- (nth 2 focus) (nth 0 focus)))
                                                 (/ (* rows .7) (- (nth 3 focus) (nth 1 focus)))))
                                   policy))))))
       (when (> scale 1)
         (let* ((display (plist-get context :metrics))
                (ink (or (plist-get state :subject-ink)
                         (setf (plist-get state :subject-ink)
                               (etaf-screensaver--glyph-subject-ink
                                (plist-get state :frames)
                                (plist-get context :background)))))
                (metrics (list :char-width (or (plist-get display :char-width) (frame-char-width))
                               :line-height (or (plist-get display :line-height) (frame-char-height))
                               :ascent (or (plist-get display :ascent) 82)
                               :family (etaf-screensaver--glyph-font-stack)
                               :ink ink))
                (key (list scale metrics))
                (cache (or (plist-get state :glyph-cache)
                           (setf (plist-get state :glyph-cache) (make-hash-table :test #'equal))))
                (paints (or (plist-get state :glyph-paints)
                            (setf (plist-get state :glyph-paints) (make-hash-table :test #'equal)))))
           (unless (equal key (plist-get state :glyph-key))
             (clrhash cache) (clrhash paints)
             (setf (plist-get state :glyph-key) key))
           (etaf-screensaver--glyph-rows
            (car (etaf-screensaver--reel-entry state (plist-get state :index)))
            focus columns rows scale metrics cache paints subject
            (etaf-screensaver--reel-text-native-rows state context focus subject))))))
   (etaf-screensaver--reel-text-native-rows state context)))

(defun etaf-screensaver--reel-blank-subject (line start end subject)
  "Return LINE with SUBJECT characters between columns START and END blanked.
Cell widths, other characters and their faces are preserved."
  (let ((column 0) (position 0) (length (length line)) parts)
    (while (< position length)
      (let* ((char (aref line position)) (width (char-width char)))
        (if (and (>= column start) (< column end) (gethash char subject))
            (push (make-string width ?\s) parts)
          (push (substring line position (1+ position)) parts))
        (cl-incf position)
        (cl-incf column width)))
    (when parts (apply #'concat (nreverse parts)))))

(defun etaf-screensaver--reel-text-native-rows (state context &optional exclude subject)
  "Fit STATE's text into CONTEXT, blanking EXCLUDE's SUBJECT characters.
Center, crop or pad at native cell size without changing cached source rows.
Only the settled subject clears for its enlarged replacement; transient effect
glyphs inside the rectangle keep playing at native size."
  (let* ((columns (plist-get context :columns))
         (rows (plist-get context :rows))
         (source-width (plist-get state :width))
         (source-height (plist-get state :height))
         (entry (etaf-screensaver--reel-entry state (plist-get state :index)))
         (frame-rows (car entry))
         (first (max 0 (/ (- source-height rows) 2)))
         (visible (min rows source-height))
         (top (max 0 (/ (- rows source-height) 2)))
         (left (max 0 (/ (- columns source-width) 2)))
         (right (max 0 (- columns source-width left)))
         (crop (max 0 (/ (- source-width columns) 2))))
    (append
     (make-list top "")
     (cl-loop for row below visible
              collect
              (let* ((source-row (+ first row))
                     (line (aref frame-rows source-row))
                     (blank (and exclude subject
                                 (<= (nth 1 exclude) source-row)
                                 (< source-row (nth 3 exclude))
                                 (etaf-screensaver--reel-blank-subject
                                  line (nth 0 exclude) (nth 2 exclude) subject))))
                (when blank (setq line blank))
                (cond ((<= source-width columns)
                       (concat (make-string left ?\s) line (make-string right ?\s)))
                      (blank (etaf-screensaver--presentation-crop line columns crop))
                      (t (etaf-screensaver--reel-slice
                          (aref (etaf-screensaver--reel-cells entry) source-row)
                          crop columns)))))
     (make-list (- rows top visible) ""))))

(defun etaf-screensaver--reel-render (state context)
  "Return STATE's current frame fitted into CONTEXT's canvas."
  (if (eq (plist-get state :kind) 'image)
      (etaf-screensaver--reel-image-rows state context)
    (etaf-screensaver--reel-text-rows state context)))

(defun etaf-screensaver--reel-step (state context)
  "Advance STATE by CONTEXT's elapsed seconds, following frame durations.
A scene duration shorter than the recording loops it from the start."
  (let* ((durations (plist-get state :durations))
         (count (length durations))
         (clock (+ (plist-get state :clock) (float (or (plist-get context :dt) 0))))
         (index (plist-get state :index))
         (guard 0))
    (while (and (< guard 10000) (>= clock (aref durations index)))
      (setq clock (- clock (aref durations index))
            index (% (1+ index) count)
            guard (1+ guard)))
    (when (= guard 10000)
      ;; An unreasonably large step should not walk the whole recording.
      (setq clock 0.0))
    (setf (plist-get state :clock) clock)
    (setf (plist-get state :index) index)))

(defun etaf-screensaver--reel-create (reel provider file)
  "Read FILE through PROVIDER for REEL and return its playback state."
  (let ((data (condition-case problem
                  (etaf-screensaver--reel-read (plist-get reel :provider) provider file)
                (etaf-screensaver-error (signal (car problem) (cdr problem)))
                (error (etaf-screensaver--fail "Cannot read recording %s: %s"
                                               file (error-message-string problem))))))
    (let* ((width (plist-get data :width))
           (height (plist-get data :height))
           (images (plist-get data :image-frames))
           (types (plist-get data :image-types))
           (frames (plist-get data :frames))
           (count (if (vectorp images) (length images)
                    (and (vectorp frames) (length frames))))
           (rate (or (plist-get data :frame-rate) (plist-get reel :frame-rate) 15))
           (durations (or (plist-get data :durations)
                          (make-vector (or count 0) (/ 1.0 rate))))
           (id (plist-get reel :id)))
      (unless (and count (> count 0))
        (etaf-screensaver--fail "Reel %s did not produce any frames" id))
      (unless (and (vectorp durations) (= (length durations) count)
                   (cl-every (lambda (duration)
                               (and (numberp duration) (> duration 0)))
                             durations))
        (etaf-screensaver--fail "Reel %s has invalid frame durations" id))
      (if images
          (progn
            (unless (cl-every #'stringp images)
              (etaf-screensaver--fail "Reel %s reports a non-file image frame" id))
            (when types
              (unless (and (vectorp types) (= (length types) count)
                           (cl-every (lambda (type) (and type (symbolp type))) types))
                (etaf-screensaver--fail "Reel %s reports invalid image formats" id)))
            (let ((size (plist-get data :image-size)))
              (when size
                (unless (and (consp size)
                             (integerp (car size)) (integerp (cdr size))
                             (> (car size) 0) (> (cdr size) 0))
                  (etaf-screensaver--fail "Reel %s reports an invalid image size" id))))
            (list :kind 'image :image-frames images :image-size (plist-get data :image-size)
                  :image-sizes (make-vector count nil) :image-layout nil
                  :image-types (if types (copy-sequence types) (make-vector count nil))
                  :durations durations :index 0 :clock 0.0))
        (progn
          (unless (and (integerp width) (<= 1 width 4096)
                       (integerp height) (<= 1 height 4096))
            (etaf-screensaver--fail "Reel %s reports an invalid canvas size" id))
          (unless (and count (> count 0) (cl-every #'stringp frames))
            (etaf-screensaver--fail "Reel %s did not produce any frames" id))
          (list :kind 'text :frames frames :durations durations :ansi (plist-get data :ansi)
                :width width :height height :index 0 :clock 0.0
                :text-scale etaf-screensaver-reel-text-scale :text-focus nil
                :text-focus-index nil
                :glyph-key nil :glyph-cache nil :glyph-paints nil
                :glyph-subject nil :subject-ink nil :cache (make-vector count nil)))))))

(defun etaf-screensaver-register-reel (spec)
  "Register the recorded animation described by SPEC and return the scene.
SPEC is a plist, optionally wrapped as (etaf-reel ...), with :id, :provider
and :recording plus optional :title, :summary, :tags, :width, :height,
:frame-rate, :frame-count, :source, :license and :background.  :recording is
resolved relative to the reel file's directory.  Registering the same :id
again replaces the previous scene in place.

Registration holds only metadata.  Playback reads the recording at scene
creation, or incrementally for the next queued built-in image bundle.
Playback follows the recording's own per-frame timing.  Text subject sizing
uses `etaf-screensaver-reel-text-scale'; surrounding text keeps native center
fitting.  Image frames retain native size or downscale proportionally."
  (let* ((reel (if (eq (car-safe spec) 'etaf-reel) (cdr spec) spec)))
    (etaf-screensaver--reel-validate reel)
    (let* ((id (plist-get reel :id))
           (provider-id (plist-get reel :provider))
           (provider (cdr (assq provider-id etaf-screensaver--reel-providers)))
           (file (etaf-screensaver--reel-file (plist-get reel :recording)))
           (title (or (plist-get reel :title) (file-name-base file)))
           (rate (or (plist-get reel :frame-rate) 15))
           (duration (or (plist-get reel :duration)
                         (let ((count (plist-get reel :frame-count)))
                           (and (integerp count) (> count 0) (/ (float count) rate))))))
      (unless (file-regular-p file)
        (etaf-screensaver--fail "Reel %s recording does not exist: %s" id file))
      (let ((scene
             (etaf-screensaver--register
              id
              (list
               :title title
               :summary
               (or (plist-get reel :summary)
                   (format "%s %s recording (%s%s); %d frames at %s fps"
                           provider-id (if (eq (plist-get reel :kind) 'image) "image" "text")
                           (plist-get provider :title)
                           (if-let* ((source (plist-get reel :source)))
                               (format ": %s" source)
                             "")
                           (or (plist-get reel :frame-count) 0) rate))
               :tags (append (plist-get reel :tags) (list 'reel provider-id))
               :frame-rate rate
               :duration duration
               :background (plist-get reel :background)
               :create (lambda (_context) (etaf-screensaver--reel-create reel provider file))
               :step #'etaf-screensaver--reel-step
               :render #'etaf-screensaver--reel-render
               :resize (lambda (state _context) state)))))
        ;; This private descriptor travels with the compiled scene snapshot.
        ;; Do not look up a replacement registration or inspect its closure.
        ;; Custom providers retain their existing synchronous :read contract.
        (when (eq (plist-get provider :read) 'etaf-screensaver--frames-read)
          (setf (etaf-screensaver--scene-reel-source scene) (list provider-id provider file)))
        scene))))

(provide 'etaf-screensaver-reel)
;;; etaf-screensaver-reel.el ends here
