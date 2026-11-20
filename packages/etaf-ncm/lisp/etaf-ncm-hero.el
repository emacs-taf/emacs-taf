;;; etaf-ncm-hero.el --- Cover artwork for the now-playing page -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The now-playing page fills itself with one picture: the playing song's
;; artwork over a blurred copy of the same artwork, fading into the flat panel
;; that carries the track, the spectrum and the transport.  Both the picture and
;; the accent colour come from the cover file the player already downloaded, so
;; opening the page costs no network request.
;;
;; Every builder here fails open.  Without ffmpeg, or with an unreadable cover,
;; they return nil and the page falls back to the plain cover on the panel
;; colour.  The picture is cached under `etaf-ncm-state-directory' and keyed by
;; the cover's identity, which includes its modification time, so a new
;; download never shows the old blur.

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'etaf-ncm-service)

(defcustom etaf-ncm-hero-program "ffmpeg"
  "Program that builds the now-playing page's backdrop."
  :type 'string
  :group 'etaf-ncm)

(defconst etaf-ncm-hero--fade 0.34
  "Fraction of the picture's width that fades into the panel colour.
The picture stays visible on the left and reaches the flat panel colour at its
right edge, so the panel beside it continues the same colour without a seam.")

(defconst etaf-ncm-hero--fade-steps 80
  "Number of strips the fade is drawn with.
One strip per step keeps the gradient smooth before the closing blur; fewer
steps leave visible bands in a large window.")

(defconst etaf-ncm-hero--keep-days 7
  "Days a generated backdrop stays on disk before a new one replaces it.
A resize produces one file per window size, so the directory would otherwise
grow with every drag of the frame edge.")

(defvar etaf-ncm-hero--accents (make-hash-table :test #'equal)
  "Sampled accent colours keyed by (FILE . MTIME).")

(defun etaf-ncm-hero--directory ()
  "Return the directory holding generated page backdrops."
  (expand-file-name "hero" etaf-ncm-state-directory))

(defun etaf-ncm-hero--identity (file)
  "Return FILE's identity as a string: its size and modification time.
A cached picture is only reused while the cover file behind it is unchanged."
  (let ((attributes (file-attributes file)))
    (format "%s-%s" (file-attribute-size attributes)
            (file-attribute-modification-time attributes))))

(defconst etaf-ncm-hero--version 11
  "Version of the picture this module draws.
Part of every cache key, so changing the recipe never serves an old backdrop.")

(defun etaf-ncm-hero-accent (file)
  "Return FILE's average colour as a hex string, or nil.
The spectrum and the current lyric line take their colour from the artwork, so
the page reads as one picture instead of a red accent pasted on a blue cover."
  (when (and (stringp file) (file-readable-p file)
             (executable-find etaf-ncm-hero-program))
    (let ((key (cons (expand-file-name file) (etaf-ncm-hero--identity file))))
      (or (gethash key etaf-ncm-hero--accents)
          (let ((pixel (ignore-errors
                         (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (when (eq 0 (call-process etaf-ncm-hero-program nil t nil
                                                     "-v" "error" "-i" file
                                                     "-vf" "scale=1:1"
                                                     "-f" "rawvideo"
                                                     "-pix_fmt" "rgb24" "-"))
                             (buffer-string))))))
            (when (and (stringp pixel) (>= (length pixel) 3))
              (let ((hex (format "#%02x%02x%02x"
                                 (aref pixel 0) (aref pixel 1) (aref pixel 2))))
                (puthash key hex etaf-ncm-hero--accents)
                hex)))))))

(defun etaf-ncm-hero--key (file width height panel direction area scale)
  "Return the cache key of a backdrop built from FILE at WIDTH by HEIGHT.
PANEL is the colour the picture fades into, DIRECTION the edge it fades on and
AREA where the sharp copy sits, so neither a palette change, a layout flip nor
a move of the artwork reuses the other picture."
  (secure-hash 'md5 (format "%d|%s|%s|%d|%d|%s|%s|%S|%s"
                            etaf-ncm-hero--version
                            (expand-file-name file)
                            (etaf-ncm-hero--identity file)
                            width height panel direction area scale)))

(defun etaf-ncm-hero--prune (directory)
  "Delete backdrops in DIRECTORY older than `etaf-ncm-hero--keep-days'."
  (let ((cutoff (time-subtract (current-time)
                               (days-to-time etaf-ncm-hero--keep-days))))
    (ignore-errors
      (dolist (file (directory-files directory t "\\.jpg\\'"))
        (when (time-less-p (file-attribute-modification-time
                            (file-attributes file))
                           cutoff)
          (delete-file file))))))

(defun etaf-ncm-hero--luma (hex)
  "Return HEX's perceived lightness in 0..1, or nil when it is not a colour.
HEX is `#RRGGBB'; the filter receives the colour without its `#', which is why
the leading hash is optional here — reading only the hash form made every panel
look dark and the light host kept the dim slab."
  (when (and (stringp hex)
             (string-match-p "\\`#?[[:xdigit:]]\\{6\\}\\'" hex))
    (let ((v (string-to-number (substring hex (if (eq (aref hex 0) ?#) 1 0)) 16)))
      (/ (+ (* 0.299 (ash (logand v #xff0000) -16))
            (* 0.587 (ash (logand v #x00ff00) -8))
            (* 0.114 (logand v #x0000ff)))
         255.0))))

(defun etaf-ncm-hero--strips (width height start panel direction)
  "Return ffmpeg `drawbox' filters fading a WIDTH by HEIGHT picture into PANEL.
START is where the fade begins in pixels; DIRECTION is `right' for a panel
beside the picture or `down' for one beneath it.  Each step covers a slice of
the fade with the next alpha, so the stack reads as one gradient once the
closing blur runs."
  (cl-loop for index below etaf-ncm-hero--fade-steps
           for from = (/ (float index) etaf-ncm-hero--fade-steps)
           for to = (/ (float (1+ index)) etaf-ncm-hero--fade-steps)
           for a = (round (+ start (* (- (if (eq direction 'down) height width)
                                       start)
                                    from)))
           for b = (round (+ start (* (- (if (eq direction 'down) height width)
                                       start)
                                    to)))
           collect (if (eq direction 'down)
                       (format "drawbox=x=0:y=%d:w=iw:h=%d:color=0x%s@%.3f:t=fill"
                               a (max 1 (- b a)) panel to)
                     (format "drawbox=x=%d:y=0:w=%d:h=ih:color=0x%s@%.3f:t=fill"
                             a (max 1 (- b a)) panel to))))

(defun etaf-ncm-hero--art-rect (width height area)
  "Return the sharp picture's (X Y WIDTH HEIGHT) inside a hero of WIDTH by HEIGHT.
AREA is the (X Y WIDTH HEIGHT) region of the hero the cover centres in, or nil
for the whole picture.  The sharp copy keeps a margin of the region on every
side so the blurred copy still reads as the same artwork behind it."
  (pcase-let* ((`(,ax ,ay ,aw ,ah) (or area (list 0 0 width height)))
               (edge (round (min (* aw 0.82) (* ah 0.86))))
               (edge (max 32 (min edge (* 2 (round (min width height)))))))
    (list (+ ax (round (/ (- aw edge) 2)))
          (+ ay (round (/ (- ah edge) 2)))
          edge edge)))

(defun etaf-ncm-hero--grade (panel)
  "Return the ffmpeg filter that tints the backdrop for PANEL.
A dark host dims the cover so the words sit on it; a light host brightens and
desaturates it, because the same dim slab beside a white pane is a black band
the page cannot recover from."
  (if (> (or (etaf-ncm-hero--luma panel) 0) 0.5)
      "eq=brightness=0.42:saturation=0.35"
    "eq=brightness=-0.26:saturation=1.10"))

(defun etaf-ncm-hero--filter (width height panel direction area accent)
  "Return the ffmpeg filter graph for a WIDTH by HEIGHT backdrop in PANEL.
The background is the cover scaled to cover the page and blurred hard, the way
a poster behind the controls reads: one picture, no crop seam and no empty
band, and the artwork is never stretched.  A sharp copy of the whole cover sits
in AREA, an (X Y WIDTH HEIGHT) region or nil for the centre.  DIRECTION
(`right' or `down') fades the far edge into the flat PANEL colour where the
text begins."
  (let* ((panel (substring panel 1))
         (span (if (eq direction 'down) height width))
         (from (cond ((and area (< (nth 2 area) width))
                      (max 0.35 (- (/ (float (nth 2 area)) width) 0.10)))
                     ;; A long gradient, not a band: the picture darkens into
                     ;; the text colour over its last third, so the text sits on
                     ;; the artwork with no edge between them.
                     (t (- 0.66 etaf-ncm-hero--fade 0.0))))
         (start (round (* span from)))
         (art (etaf-ncm-hero--art-rect width height area)))
    (pcase-let ((`(,left ,top ,edge ,_) art))
      (format (concat "[0:v]split=2[bg][sharp];"
                      ;; The background is the whole cover, fitted and padded
                      ;; with its own average colour, then blurred as one
                      ;; picture: no crop, no stretch and no visible edge,
                      ;; because the page takes the artwork's colour outward
                      ;; instead of cutting the artwork away.
                      "[bg]scale=%d:%d:force_original_aspect_ratio=decrease,"
                      "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=0x%s,"
                      "gblur=sigma=54," (etaf-ncm-hero--grade panel) "[blur];"
                      ;; The sharp copy is square, like the cover itself:
                      ;; scale up and crop to the square instead of fitting and
                      ;; padding, because `pad' refuses a canvas one pixel
                      ;; smaller than its input and killed the whole render.
                      "[sharp]scale=%d:%d:force_original_aspect_ratio=increase,"
                      "crop=%d:%d[art];"
                      "[blur][art]overlay=%d:%d:format=auto[mixed];"
                      "[mixed]%s[out]")
              width height width height (substring accent 1)
              edge edge edge edge
              left top
              (mapconcat #'identity
                         (etaf-ncm-hero--strips width height start panel direction)
                         ",")))))
(defun etaf-ncm-hero--build (cover file width height panel direction area accent)
  "Render COVER into FILE at WIDTH by HEIGHT in PANEL, fading on DIRECTION.
The render is synchronous on purpose: an asynchronous ffmpeg whose failure
nobody reads leaves the page with no picture and no explanation, which is what
made the backdrop appear only sometimes.  One frame of a cover takes a fraction
of a second, and the call only happens when the page size changes."
  (ignore-errors (make-directory (file-name-directory file) t))
  (let ((status (ignore-errors
                  (call-process etaf-ncm-hero-program nil nil nil
                                "-v" "error" "-y" "-i" cover
                                "-vf" (etaf-ncm-hero--filter
                                        width height panel direction area accent)
                                "-frames:v" "1" "-q:v" "2" file))))
    (and (eq status 0) (file-readable-p file) file)))

(defun etaf-ncm-hero-file (cover width height panel direction &optional area scale callback)
  "Return a page backdrop from COVER at WIDTH by HEIGHT pixels in PANEL.
The picture is one frame: COVER scaled to cover the page and blurred, with a
sharp copy of the whole cover over AREA — an (X Y WIDTH HEIGHT) region, or nil
for the centre — fading into PANEL on the DIRECTION edge (`right' or `down')
where the text begins.  The picture is drawn at SCALE times the pixels the
cells cover (two on a Retina frame) and Ebox shrinks it back on display, which
keeps the sharp copy crisp.
A backdrop already on disk returns its file; otherwise it is built now and the
file returns when it landed.  CALLBACK is accepted for callers that want the
asynchronous shape but the build is synchronous, so it is called with the file
before returning.  Nil when COVER is unreadable, PANEL is not a hex colour,
ffmpeg is unavailable, or the render failed."
  (when (and (stringp cover) (file-readable-p cover)
             (stringp panel) (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" panel)
             (executable-find etaf-ncm-hero-program)
             (> width 16) (> height 16))
    (let* ((accent (or (etaf-ncm-hero-accent cover) panel))
           (scale (max 1 (min 3 (or scale 1))))
           (area (and area (mapcar (lambda (value) (* (max 0 value) scale)) area)))
           (directory (etaf-ncm-hero--directory))
           (file (expand-file-name
                  (concat (etaf-ncm-hero--key cover width height panel direction
                                              (and area (mapcar (lambda (v) (/ v scale)) area))
                                              scale)
                          ".jpg")
                  directory)))
      (unless (file-readable-p file)
        (etaf-ncm-hero--prune directory)
        (etaf-ncm-hero--build cover file (* width scale) (* height scale)
                              panel direction area accent))
      (if (file-readable-p file)
          (progn (when callback (funcall callback file)) file)
        nil))))

(provide 'etaf-ncm-hero)
;;; etaf-ncm-hero.el ends here
