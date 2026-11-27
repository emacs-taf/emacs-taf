;;; etaf-md-views.el --- Views of the markdown previewer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Presentation layer of etaf-md.  The document body comes from the
;; shared `etaf-ui-markdown' renderer; this module keeps what is specific to
;; the previewer: the face-derived or named palette, the front-matter header,
;; the reading column, and the media layer that turns images, videos and HTML
;; media elements into poster cards backed by ETAF's image and video Hosts.
;;
;; The functions take a parsed document plus a rendering environment and
;; return ETAF views; they never read session state directly, so one code path
;; renders headless tests and a mounted buffer alike.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'image)
(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function clear-image-cache "image.c" (&optional filter))
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md-cache)
(require 'etaf-md-theme)
(require 'etaf-md-env)

(declare-function etaf-md-locate "etaf-md-model" (session index))

(defconst etaf-md--alert-labels
  '((note . "笔记") (tip . "提示") (important . "重要")
    (warning . "警告") (caution . "小心"))
  "Chinese labels of the GitHub alert kinds, for ENV's `:alert-labels'.")

(defconst etaf-md--video-extensions
  '("mp4" "mov" "m4v" "webm" "avi" "mkv" "ogv" "mpg" "mpeg" "wmv" "flv" "3gp")
  "File extensions rendered as a video card.")

(defun etaf-md--env-color (env key)
  "Return ENV's color for semantic KEY.
ENV's face-derived `:palette', when present, wins over the named theme; an
unknown key in either source signals `etaf-md-error'."
  (if-let* ((palette (plist-get env :palette)))
      (or (cdr (assq key palette))
          (signal 'etaf-md-error
                  (list (format "Unknown markdown preview color: %S" key))))
    (etaf-md-color key (plist-get env :theme))))

(defconst etaf-md--meta-labels
  '(("author" . "作者") ("date" . "日期") ("version" . "版本")
    ("license" . "许可") ("status" . "状态"))
  "Front matter keys shown in the document header, with their labels.")

(defun etaf-md--meta-tags (meta)
  "Return the tag list of front matter META.
Both `[a, b]' and `a, b' spellings are accepted."
  (let ((raw (cdr (assoc "tags" meta))))
    (when (and raw (not (string-empty-p raw)))
      (let ((raw (replace-regexp-in-string "[][]" "" raw)))
        (delq nil
              (mapcar (lambda (item)
                        (let ((item (string-trim item)))
                          (unless (string-empty-p item) item)))
                      (split-string raw ",")))))))

(defun etaf-md--meta-node (document env)
  "Return the document header for DOCUMENT's front matter, or nil.
The header carries the title, tag chips and the labeled metadata line, so a
document with front matter opens on a page-like header instead of raw text."
  (let* ((meta (plist-get document :meta))
         (title (cdr (assoc "title" meta)))
         (tags (etaf-md--meta-tags meta))
         ;; A key the document leaves out must not leave its separator behind:
         ;; the header reads as one run of labels, not a row of floating dots.
         (labels (mapconcat
                  #'identity
                  (delq nil
                        (mapcar
                         (lambda (key)
                           (let ((value (cdr (assoc key meta))))
                             (when (and value (not (string-empty-p value)))
                               (format "%s %s"
                                       (cdr (assoc key etaf-md--meta-labels))
                                       value))))
                         '("author" "date" "version" "license" "status")))
                  "  ·  ")))
    (when title
      (etaf-node 'column
                 (list :width 'stretch :item-gap '(lh 1))
                 (append
                  (list
                   (etaf-node 'text
                              (list :font-weight 'bold
                                    ;; The page title is the document's first
                                    ;; level and reads above a body heading.
                                    :font-size 2.2
                                    :color (etaf-md--env-color env :heading))
                              (list title)))
                  (when tags
                    (list
                     (etaf-node 'flex
                                (list :width 'stretch :gap '((lh 0) (ch 1)))
                                (mapcar (lambda (tag)
                                          (etaf-node 'etaf-tag
                                                     (list :text tag :variant 'neutral)
                                                     nil))
                                        tags))))
                  (when (and labels (not (string-empty-p labels)))
                    (list (etaf-node 'text
                                     (list :color (etaf-md--env-color env :muted))
                                     (list labels)))))))))

;;; ---------------------------------------------------------------------------
;;; Inline rendering
;;; ---------------------------------------------------------------------------

(defun etaf-md--spacer (&optional lines)
  "Return an empty spacer Box LINES lines tall."
  (etaf-node 'box (list :height (list 'lh (or lines 1))) nil))

(defun etaf-md--divider (&optional label)
  "Return a horizontal divider View, optionally labeled."
  (etaf-node 'etaf-divider (list :orientation 'horizontal :label label) nil))

(defun etaf-md--activate-media (env kind path fallback)
  "Activate media PATH of KIND in ENV, falling back to FALLBACK.
Consults ENV's `:open-media' callback first; returning non-nil marks the
activation handled, while nil calls FALLBACK with no arguments."
  (let ((handler (plist-get env :open-media)))
    (unless (and handler (funcall handler kind path))
      (funcall fallback))))

(defun etaf-md--inline-image-view (node env)
  "Return the inline chip View of image NODE in ENV."
  (let* ((alt (or (plist-get node :alt) "图片"))
         (url (plist-get node :url))
         (remote (etaf-md--remote-url-p url))
         (target (if remote url (etaf-md--absolute-media url env)))
         (kind (etaf-md--media-kind target))
         (hover (when (if (plist-member env :link-hover) (plist-get env :link-hover) t)
                  (etaf-md--env-color env :accent-soft))))
    (etaf-node 'text
               (append
                (list :color (etaf-md--env-color env :accent)
                      :background-color (etaf-md--env-color env :panel2)
                      :role 'link :tab-index 0 :pointer 'hand
                      :help-echo (or url alt)
                      :on-press (lambda ()
                                  (etaf-md--activate-media
                                   env kind target
                                   (lambda ()
                                     (let ((lb (plist-get env :open-lightbox)))
                                       (unless (and (not remote) (eq kind 'image)
                                                    (functionp lb)
                                                    (funcall lb target alt))
                                         (funcall (plist-get env :open-url) url)))))))
                (when hover (list :hover-style (list :background-color hover))))
               (list (format " 🖼 %s " alt)))))

;;; ---------------------------------------------------------------------------
;;; Media blocks
;;; ---------------------------------------------------------------------------

(defun etaf-md--media-kind (path)
  "Return `video' or `image' for PATH by extension."
  (if (member (downcase (or (file-name-extension path) ""))
              etaf-md--video-extensions)
      'video
      'image))

(defun etaf-md--remote-url-p (url)
  "Return non-nil when URL names a remote resource (not local or `file://').
A scheme longer than one letter other than `file:' is remote (`http:',
`https:', `mailto:', `tel:'); a single letter is a Windows drive (`C:/notes')."
  (and (stringp url)
       (not (string-match-p "\\`file://" (downcase url)))
       (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]+:" url)))

(defun etaf-md--absolute-media (path env)
  "Return PATH resolved against ENV's base directory."
  (let ((path (if (string-match-p "\\`file://" path)
                  (substring path 7)
                path)))
    (expand-file-name path (or (plist-get env :dir) default-directory))))

(defconst etaf-md--media-pixels-cache-limit 256
  "Maximum file pixel probes retained per process.")

(defvar etaf-md--media-pixels-cache (make-hash-table :test #'equal)
  "Media probes keyed by file identity (path, size, modification time and prober).
Repeated previews of an unchanged file reuse the probe result; a changed
size or timestamp re-probes the bytes on disk.  One file can be measured by
several probes (an image's pixel size, a video's pixel size and a video's
playback metadata), so the prober is part of the key and a result never
answers a different probe.")

(defun etaf-md--media-pixels-cached (path prober)
  "Return PATH's result from PROBER, reusing unchanged file probes.
PATH without readable attributes is probed directly."
  (let* ((attributes (file-attributes path))
         (key (and attributes
                   (list (expand-file-name path)
                         (file-attribute-size attributes)
                         (file-attribute-modification-time attributes)
                         prober)))
         (missing (make-symbol "missing-media-pixels")))
    (if (null key)
        (funcall prober path)
      (let ((cached (gethash key etaf-md--media-pixels-cache missing)))
        (if (not (eq cached missing))
            cached
          (when (> (hash-table-count etaf-md--media-pixels-cache)
                   etaf-md--media-pixels-cache-limit)
            (clrhash etaf-md--media-pixels-cache))
          (puthash key (funcall prober path)
                   etaf-md--media-pixels-cache))))))

(defun etaf-md--svg-declared-size (path)
  "Return the size PATH declares in its own header, or nil.
A vector states the size it should occupy via explicit numeric `width'/`height'
attributes (ignoring percentage values) or its `viewBox' width and height.
Reading that header costs a few hundred bytes without rasterising the drawing,
and falling back to `viewBox' keeps responsive SVGs at their true aspect ratio."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (when (ignore-errors (insert-file-contents-literally path nil 0 4096))
      (goto-char (point-min))
      (let ((case-fold-search t))
        (when (re-search-forward "<svg\\b[^>]*>" nil t)
          (let* ((tag (match-string-no-properties 0))
                 (width (and (string-match
                              "\\bwidth=[\"']\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(?:px\\)?[\"']"
                              tag)
                             (string-to-number (match-string 1 tag))))
                 (height (and (string-match
                               "\\bheight=[\"']\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\(?:px\\)?[\"']"
                               tag)
                              (string-to-number (match-string 1 tag))))
                 (vb (when (string-match
                            "\\bviewbox=[\"'][ \t]*[-+0-9.eE]+[ \t,]+[-+0-9.eE]+[ \t,]+\\([0-9.eE]+\\)[ \t,]+\\([0-9.eE]+\\)[ \t]*[\"']"
                            tag)
                       (cons (string-to-number (match-string 1 tag))
                             (string-to-number (match-string 2 tag)))))
                 (vb-w (and vb (> (car vb) 0) (car vb)))
                 (vb-h (and vb (> (cdr vb) 0) (cdr vb))))
            (cond
             ((and width height (> width 0) (> height 0))
              (cons width height))
             ((and width (> width 0) vb-w vb-h)
              (cons width (* vb-h (/ (float width) vb-w))))
             ((and height (> height 0) vb-w vb-h)
              (cons (* vb-w (/ (float height) vb-h)) height))
             ((and vb-w vb-h)
              (cons vb-w vb-h)))))))))

(defun etaf-md--raster-header-pixels (path)
  "Return raster image pixel size `(WIDTH . HEIGHT)' from PATH's file header.
Supports PNG, GIF, JPEG and WebP without requiring a graphical frame or full
image decode; returns nil for unrecognized or unreadable files."
  (when (and (stringp path) (file-readable-p path))
    (ignore-errors
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 65536)
        (let ((size (buffer-size)))
          (cond
           ;; PNG: 8-byte signature + IHDR chunk (width at 17..20, height at 21..24)
           ((and (>= size 24)
                 (equal (buffer-substring-no-properties 1 9)
                        "\x89PNG\r\n\x1a\n"))
            (let ((w (+ (ash (char-after 17) 24) (ash (char-after 18) 16)
                        (ash (char-after 19) 8) (char-after 20)))
                  (h (+ (ash (char-after 21) 24) (ash (char-after 22) 16)
                        (ash (char-after 23) 8) (char-after 24))))
              (when (and (> w 0) (> h 0)) (cons w h))))
           ;; GIF87a / GIF89a: 16-bit LE width at 7..8, height at 9..10
           ((and (>= size 10)
                 (member (buffer-substring-no-properties 1 7) '("GIF87a" "GIF89a")))
            (let ((w (+ (char-after 7) (ash (char-after 8) 8)))
                  (h (+ (char-after 9) (ash (char-after 10) 8))))
              (when (and (> w 0) (> h 0)) (cons w h))))
           ;; WebP: RIFF....WEBP + VP8X / VP8L / VP8 chunk
           ((and (>= size 30)
                 (equal (buffer-substring-no-properties 1 5) "RIFF")
                 (equal (buffer-substring-no-properties 9 13) "WEBP"))
            (let ((chunk (buffer-substring-no-properties 13 17)))
              (cond
               ((equal chunk "VP8X")
                (let ((w (1+ (+ (char-after 25) (ash (char-after 26) 8)
                                (ash (char-after 27) 16))))
                      (h (1+ (+ (char-after 28) (ash (char-after 29) 8)
                                (ash (char-after 30) 16)))))
                  (when (and (> w 0) (> h 0)) (cons w h))))
               ((and (equal chunk "VP8L") (= (char-after 21) #x2f))
                (let* ((bits (+ (char-after 22) (ash (char-after 23) 8)
                                (ash (char-after 24) 16) (ash (char-after 25) 24)))
                       (w (1+ (logand bits #x3fff)))
                       (h (1+ (logand (ash bits -14) #x3fff))))
                  (when (and (> w 0) (> h 0)) (cons w h))))
               ((equal chunk "VP8 ")
                (let ((w (logand (+ (char-after 27) (ash (char-after 28) 8)) #x3fff))
                      (h (logand (+ (char-after 29) (ash (char-after 30) 8)) #x3fff)))
                  (when (and (> w 0) (> h 0)) (cons w h)))))))
           ;; JPEG: SOI (FF D8) followed by marker segments until SOF0..SOF15
           ((and (>= size 4)
                 (= (char-after 1) #xff)
                 (= (char-after 2) #xd8))
            (let ((pos 3)
                  (found nil))
              (while (and (not found) (< (1+ pos) size))
                (while (and (< pos size) (/= (char-after pos) #xff))
                  (setq pos (1+ pos)))
                (while (and (< pos size) (= (char-after pos) #xff))
                  (setq pos (1+ pos)))
                (when (< pos size)
                  (let ((marker (char-after pos)))
                    (setq pos (1+ pos))
                    (cond
                     ;; Standalone markers without length
                     ((or (= marker #x01)
                          (and (>= marker #xd0) (<= marker #xd9)))
                      nil)
                     ;; Start of Frame markers carrying height/width
                     ((and (memq marker '(#xc0 #xc1 #xc2 #xc3 #xc5 #xc6 #xc7
                                               #xc9 #xca #xcb #xcd #xce #xcf))
                           (<= (+ pos 6) size))
                      (let ((h (+ (ash (char-after (+ pos 3)) 8)
                                  (char-after (+ pos 4))))
                            (w (+ (ash (char-after (+ pos 5)) 8)
                                  (char-after (+ pos 6)))))
                        (when (and (> w 0) (> h 0))
                          (setq found (cons w h)))))
                     ((<= (1+ pos) size)
                      (let ((len (+ (ash (char-after pos) 8)
                                    (char-after (1+ pos)))))
                        (if (< len 2)
                            (setq pos size)
                          (setq pos (+ pos len)))))
                     (t (setq pos size))))))
              found))))))))

(defun etaf-md--probe-image-pixels (path)
  "Return PATH's image pixel size as (WIDTH . HEIGHT), or nil.
Drop PATH's entry first so an updated file is measured from its bytes rather
than the previous render.  On non-graphical frames, inspects PNG/GIF/JPEG/WebP
headers directly so terminal and batch renders preserve aspect ratio."
  (cond
   ((string-suffix-p ".svg" (downcase path))
    (etaf-md--svg-declared-size path))
   ((display-graphic-p)
    (or (ignore-errors
          (clear-image-cache path)
          (when-let* ((image (create-image path nil nil)))
            (let ((size (image-size image t)))
              (cons (car size) (cdr size)))))
        (etaf-md--raster-header-pixels path)))
   (t
    (etaf-md--raster-header-pixels path))))

(defun etaf-md--image-pixels (path)
  "Return PATH's pixel size as (WIDTH . HEIGHT), or nil.
Unchanged files reuse their cached probe."
  (when (and (stringp path) (file-readable-p path))
    (etaf-md--media-pixels-cached
     path #'etaf-md--probe-image-pixels)))

(defun etaf-md--probe-video-pixels (path)
  "Return PATH's video pixel size as (WIDTH . HEIGHT), or nil."
  (when-let* ((ffprobe (executable-find "ffprobe")))
    (ignore-errors
      (with-temp-buffer
        (when (zerop (call-process ffprobe nil t nil
                                   "-v" "error" "-select_streams" "v:0"
                                   "-show_entries" "stream=width,height"
                                   "-of" "csv=p=0:s=x" path))
          (let ((line (string-trim (buffer-string))))
            (when (string-match "\\`\\([0-9]+\\)x\\([0-9]+\\)" line)
              (cons (string-to-number (match-string 1 line))
                    (string-to-number (match-string 2 line))))))))))

(defun etaf-md--video-pixels (path)
  "Return PATH's video pixel size as (WIDTH . HEIGHT), or nil.
Unchanged files reuse their cached probe."
  (etaf-md--media-pixels-cached
   path #'etaf-md--probe-video-pixels))

(defun etaf-md--probe-video-source (path)
  "Return PATH's native playback metadata, or nil when unsupported."
  (ignore-errors (etaf-video-source-info path)))

(defun etaf-md--native-video-source (path)
  "Return PATH's playback metadata when the native player can run it.
Needs ffmpeg on `exec-path' and an ffprobe-readable source; unchanged files
reuse their cached probe."
  (when (executable-find "ffmpeg")
    (etaf-md--media-pixels-cached
     path #'etaf-md--probe-video-source)))

(defun etaf-md--media-grid-for-pixels (pixels max-columns &optional max-rows)
  "Return the (COLUMNS . ROWS) grid for PIXELS capped by MAX-COLUMNS.
MAX-ROWS defaults to `etaf-md--media-max-rows' for standalone photos and
screenshots; pass a larger ceiling for typeset diagrams that should scale by
reading measure width without crushing vertical labels.  A picture whose size
could not be read keeps a card of a fixed shape rather than failing the page."
  (if (or (not (consp pixels))
          (not (numberp (car pixels)))
          (not (numberp (cdr pixels))))
      ;; A picture whose size could not be read keeps a card of a fixed shape
      ;; rather than failing the whole page.
      (cons (min max-columns 48) 14)
    (etaf-md--media-grid-cells pixels max-columns max-rows)))

(defconst etaf-md--media-max-rows 20
  "Maximum character-row height for a standalone media card.
Prevents tall portrait photos or screenshots from dominating the viewport;
when the ceiling applies, width scales down proportionally to preserve the
source aspect ratio.")

(defun etaf-md--media-grid-cells (pixels max-columns &optional max-rows)
  "Return the (COLUMNS . ROWS) grid for measured PIXELS inside MAX-COLUMNS.
A picture is drawn at its own size and scaled down proportionally when it
exceeds MAX-COLUMNS or MAX-ROWS (defaulting to `etaf-md--media-max-rows'),
keeping the drawing inside the column and preserving the source aspect ratio
in both dimensions."
  (let* ((row-cap (or max-rows etaf-md--media-max-rows))
         (cell (etaf-md--cell-metrics))
         (cell-width (float (car cell)))
         (cell-height (float (cdr cell)))
         (natural-width (float (car pixels)))
         (natural-height (float (cdr pixels)))
         (max-w (* max-columns cell-width))
         (max-h (* row-cap cell-height))
         (scale (min 1.0 (/ max-w natural-width) (/ max-h natural-height)))
         (columns (max 1 (min max-columns
                              (round (/ (* natural-width scale) cell-width)))))
         (fitted-height (* natural-height (/ (* columns cell-width) natural-width)))
         (rows (max 1 (min row-cap
                           (round (/ fitted-height cell-height))))))
    (cons columns rows)))

(defun etaf-md--media-grid (path kind max-columns)
  "Return the (COLUMNS . ROWS) grid for media PATH of KIND.
MAX-COLUMNS caps the width; the height follows the source aspect ratio and is
capped to a third of the display so one figure cannot own the whole window.
When the height cap applies, the width shrinks with it so the figure keeps the
source aspect ratio instead of being squashed into a shorter box."
  (etaf-md--media-grid-for-pixels
   (pcase kind
     ('video (etaf-md--video-pixels path))
     (_ (etaf-md--image-pixels path)))
   max-columns))

(defun etaf-md--media-grid-fit (path max-columns max-rows)
  "Return the (COLUMNS . ROWS) grid for PATH fitted inside the two bounds.
The picture keeps its aspect ratio: the width and the height are each capped
and the smaller scale wins, so a tall screenshot cannot own the column and a
wide banner cannot grow past its card."
  (let* ((pixels (etaf-md--image-pixels path))
         (cell (etaf-md--cell-metrics))
         (cell-width (float (car cell)))
         (cell-height (float (cdr cell))))
    (if (or (not (consp pixels))
            (not (numberp (car pixels)))
            (not (numberp (cdr pixels))))
        (cons (max 1 (min max-columns 40)) (max 1 (min max-rows 10)))
      (let* ((width (float (car pixels)))
             (height (float (cdr pixels)))
             (scale (min (/ (* max-columns cell-width) width)
                         (/ (* max-rows cell-height) height)
                         1.0))
             ;; Whole cells only, and never more than the picture needs: a
             ;; rounded-up column would leave a strip of the box empty at the
             ;; side the picture is not drawn in.
             (columns (max 1 (min max-columns (floor (/ (* width scale) cell-width)))))
             (rows (max 1 (min max-rows (floor (/ (* height scale) cell-height))))))
        (cons columns rows)))))

(defun etaf-md--media-picture-size (url env max-columns max-rows)
  "Return the grid URL would need as a plain picture, or nil.
Only a local image (or an already-cached remote image) has a size; an uncached
remote source and a missing file answer nil."
  (let* ((remote (etaf-md--remote-url-p url))
         (path (if remote
                   (etaf-md-cache-image-path url)
                 (etaf-md--absolute-media url env))))
    (when (and path (file-exists-p path)
               (eq (etaf-md--media-kind path) 'image))
      (etaf-md--media-grid-fit path max-columns max-rows))))

(defun etaf-md--media-picture (url env max-columns max-rows)
  "Return URL drawn as a plain picture for ENV inside MAX bounds.
No figure frame and no caption: the caller owns the card or the stage around
it.  An already-cached remote image draws from its local cache; an uncached
remote source becomes a placeholder that opens in the browser."
  (let* ((remote (etaf-md--remote-url-p url))
         (path (if remote
                   (etaf-md-cache-image-path url)
                 (etaf-md--absolute-media url env)))
         (exists (and path (file-exists-p path))))
    (cond
     ((and path exists (eq (etaf-md--media-kind path) 'image))
      (let ((grid (etaf-md--media-grid-fit path max-columns max-rows)))
        (etaf-node 'image
                   (list :src path
                         :columns (car grid)
                         :rows (cdr grid)
                         :adapter 'auto)
                   nil)))
     ((and (not remote) path (not exists))
      (etaf-node 'text
                 (list :color (etaf-md--env-color env :muted))
                 (list (format "（找不到 %s）" (file-name-nondirectory path)))))
     (t
      (etaf-node 'text
                 (list :color (etaf-md--env-color env :accent)
                       :role 'link :tab-index 0
                       :help-echo url
                       :on-press (lambda ()
                                   (etaf-md--activate-media
                                    env (etaf-md--media-kind url) url
                                    (lambda ()
                                      (funcall (plist-get env :open-url) url)))))
                 (list (format "🔗 %s" url)))))))

(defun etaf-md--media-target-pixels (natural declared-width declared-height)
  "Return effective (WIDTH . HEIGHT) pixels combining NATURAL with declared size.
DECLARED-WIDTH and DECLARED-HEIGHT are positive CSS pixel bounds from HTML
`<img>' attributes.  When a dimension is declared, the image renders at that
size instead of its larger intrinsic file size, preserving NATURAL aspect ratio
when only one axis is specified."
  (let ((nat-w (and (consp natural) (numberp (car natural)) (> (car natural) 0)
                    (float (car natural))))
        (nat-h (and (consp natural) (numberp (cdr natural)) (> (cdr natural) 0)
                    (float (cdr natural))))
        (dw (and (numberp declared-width) (> declared-width 0)
                 (float declared-width)))
        (dh (and (numberp declared-height) (> declared-height 0)
                 (float declared-height))))
    (cond
     ((and dw dh) (cons dw dh))
     ((and dw nat-w nat-h) (cons dw (* nat-h (/ dw nat-w))))
     ((and dh nat-w nat-h) (cons (* nat-w (/ dh nat-h)) dh))
     (dw (cons dw dw))
     (dh (cons dh dh))
     (t natural))))

(defun etaf-md--media-card (url alt env &optional declared-kind declared-width declared-height)
  "Return a media card View for URL with ALT in ENV.
Local images and videos render through the ETAF image Host, which owns the
graphics/terminal adapters and the video poster frame; remote sources render
as a bordered placeholder that opens in the browser.  DECLARED-KIND, when
`video', preserves video classification for sources without a video extension.
DECLARED-WIDTH and DECLARED-HEIGHT, when given as positive CSS pixel counts,
bound the rendered grid to the document's declared display size."
  (let* ((remote (etaf-md--remote-url-p url))
         (cached-remote (and remote (etaf-md-cache-image-path url)))
         (path (cond (cached-remote cached-remote)
                     ((not remote) (etaf-md--absolute-media url env))))
         (kind (and path (if (eq declared-kind 'video)
                             'video
                           (etaf-md--media-kind path))))
         (media-kind (or kind
                         (if (eq declared-kind 'video)
                             'video
                           (etaf-md--media-kind url))))
         (target (if remote url (or path url)))
         (exists (and path (file-exists-p path)))
         (open (if (and (not remote) path exists)
                   ;; Local images prefer the in-buffer media lightbox when enabled;
                   ;; videos and external fallback open with the system application.
                   (lambda ()
                     (etaf-md--activate-media
                      env media-kind path
                      (lambda ()
                        (let ((lb (plist-get env :open-lightbox)))
                          (unless (and (eq media-kind 'image)
                                       (functionp lb)
                                       (funcall lb path alt))
                            (funcall (plist-get env :open-file) path))))))
                 (lambda ()
                   (etaf-md--activate-media
                    env media-kind target
                    (lambda ()
                      (let ((lb (plist-get env :open-lightbox)))
                        (unless (and cached-remote (eq media-kind 'image)
                                     (functionp lb)
                                     (funcall lb cached-remote alt))
                          (funcall (plist-get env :open-url) url))))))))
         (columns (or (plist-get env :width)
                      (when-let* ((session (plist-get env :session)))
                        (car (etaf-md--page-widths
                              session (etaf-md--read session :width))))
                      92))
         (caption (or alt (and (not remote) path (file-name-nondirectory path)) url))
         (help-label (if (and (stringp caption) (not (string-empty-p caption)))
                         caption
                       (or (and (not remote) path (file-name-nondirectory path)) url))))
    (cond
     ((and exists (eq kind 'image))
      (let* ((natural (etaf-md--image-pixels path))
             (pixels (etaf-md--media-target-pixels
                      natural declared-width declared-height))
             (grid (etaf-md--media-grid-for-pixels pixels (- columns 2)))
             (compact (and (or declared-width declared-height)
                           (<= (car grid) 16)))
             (figure
              (etaf-node 'image
                         (list :src path
                               :columns (car grid)
                               :rows (cdr grid)
                               :adapter 'auto
                               :help-echo (format "%s（按 RET 打开）" help-label))
                         nil)))
        (etaf-node 'column
                   (list :width 'stretch
                         :cross-align (if compact 'start 'center)
                         :item-gap '(lh 0))
                   (append
                    (list
                     (etaf-node 'box
                                (list :border (list '(px 1) 'solid
                                                    (etaf-md--env-color env :border))
                                      :on-press open :role 'button :tab-index 0
                                      :pointer 'hand
                                      :help-echo (format "%s（按 RET 打开）" help-label))
                                (list figure)))
                    (unless (and compact (string-empty-p caption))
                      (list (etaf-md--caption-view
                             (format "%s%s" (if (string-empty-p caption) "" "▲ ") caption)
                             env)))))))
     ((and exists (eq kind 'video))
      (let* ((native (etaf-md--native-video-source path))
             (grid (if native
                       (etaf-md--media-grid-for-pixels
                        (and (numberp (plist-get native :width))
                             (numberp (plist-get native :height))
                             (cons (plist-get native :width)
                                   (plist-get native :height)))
                        (- columns 2))
                     (etaf-md--media-grid path kind (- columns 2))))
             (card (funcall (plist-get env :video-card) path))
             (poster
              (etaf-node 'image
                         (list :src path
                               :columns (car grid)
                               :rows (cdr grid)
                               :adapter 'auto)
                         nil)))
        (cond
         ((null native)
          ;; No decoder: the poster card opens the system player as before.
          (let ((no-ffmpeg (not (executable-find "ffmpeg"))))
            (etaf-node 'column
                       (list :width 'stretch :cross-align 'center :item-gap '(lh 0)
                             :on-press open :role 'button :tab-index 0
                             :pointer 'hand
                             :help-echo (if no-ffmpeg
                                            (format "%s（按 RET 调用系统播放器；安装 ffmpeg 可内嵌播放）" caption)
                                          (format "%s（按 RET 播放）" caption)))
                       (list
                        (etaf-node 'box
                                   (list :border (list '(px 1) 'solid
                                                       (etaf-md--env-color env :border)))
                                   (list poster))
                        (etaf-md--caption-view
                         (if no-ffmpeg
                             (format "▶ %s　·　按 RET 播放（安装 ffmpeg 可内嵌播放）" caption)
                           (format "▶ %s　·　按 RET 播放" caption))
                         env)))))
         ((funcall (plist-get env :video-active-p) (car card))
          ;; Playing inline: RET toggles this card's playback.
          (let ((handle (cdr card)))
            (etaf-node 'column
                       (list :width 'stretch :cross-align 'center :item-gap '(lh 0)
                             :on-press (lambda ()
                                         (etaf-video-toggle-playback handle))
                             :role 'button :tab-index 0 :pointer 'hand
                             :help-echo (format "%s（按 RET 播放/暂停）" caption))
                       (list
                        (etaf-node 'box
                                   (list :border (list '(px 1) 'solid
                                                       (etaf-md--env-color env :border)))
                                   (list
                                    (etaf-node 'etaf-video
                                               (list :src path
                                                     :columns (car grid)
                                                     :rows (cdr grid)
                                                     :mode 'image
                                                     :autoplay t
                                                     :handle handle)
                                               nil)))
                        (etaf-md--caption-view
                         (format "▶ %s　·　按 RET 播放/暂停" caption)
                         env)))))
         (t
          ;; A decoder is available, but decoding starts only when the
          ;; reader asks for it: the card shows the poster until RET mounts
          ;; the native player in place.
          (let ((key (car card)))
            (etaf-node 'column
                       (list :width 'stretch :cross-align 'center :item-gap '(lh 0)
                             :on-press (lambda ()
                                         (etaf-md--activate-media
                                          env 'video path
                                          (lambda ()
                                            (funcall (plist-get env :activate-video) key))))
                             :role 'button :tab-index 0 :pointer 'hand
                             :help-echo (format "%s（按 RET 内嵌播放）" caption))
                       (list
                        (etaf-node 'box
                                   (list :border (list '(px 1) 'solid
                                                       (etaf-md--env-color env :border)))
                                   (list poster))
                        (etaf-md--caption-view
                         (format "▶ %s　·　按 RET 播放" caption)
                         env))))))))
     (t
      (etaf-node 'column
                 (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
                 (list
                  (etaf-node 'box
                             (list :border (list '(px 1) 'solid
                                                 (etaf-md--env-color env :border))
                                   :background-color (etaf-md--env-color env :panel)
                                   :padding '((lh 1) (ch 2))
                                   :on-press open :role 'button :tab-index 0
                                   :pointer 'hand
                                   :help-echo (format "%s（按 RET 打开）" url))
                             (list
                              (etaf-node 'text
                                         (list :color (etaf-md--env-color env :muted))
                                         (list (format "🖼 %s" caption)))
                              (etaf-node 'text
                                         (list :color (etaf-md--env-color env :faint))
                                         (list (format "  %s" url)))))
                  (etaf-md--caption-view caption env)))))))

(defun etaf-md--caption-view (text env)
  "Return a caption View for TEXT in ENV."
  (etaf-node 'text
             (list :color (etaf-md--env-color env :muted))
             (list text)))

;;; ---------------------------------------------------------------------------
;;; Block rendering
;;; ---------------------------------------------------------------------------

(declare-function etaf-md--base-env "etaf-md-model" (session))
(declare-function etaf-md--env "etaf-md-model" (session))
(declare-function etaf-md--block-marker "etaf-md-model" (block))
(declare-function etaf-md--block-empty-p "etaf-md-model" (block &optional text))
(declare-function etaf-md--card-env "etaf-md-model" (session env scope))
(declare-function etaf-md--read "etaf-md-model" (session key))
(declare-function etaf-md--write "etaf-md-model" (session key value))
(declare-function etaf-md-outline "etaf-md-model" (session))
(declare-function etaf-md-locate "etaf-md-model" (session index))
(declare-function etaf-md--open-url "etaf-md-model" (session url))

(defun etaf-md--inlines-text (inlines)
  "Return INLINES as the plain text they spell.
This walks one list of inline nodes; `etaf-md--inline-text' in the model walks
whatever shape it is handed.  They answer different questions, and sharing one
name meant whichever file loaded last decided how a heading's own block was
read: the list walker found no text in a block and the page painted the
heading's marker alone."
  (mapconcat
   (lambda (inline)
     (cond ((eq (plist-get inline :type) 'footnote-ref)
            (format "[%s]" (or (plist-get inline :number)
                               (plist-get inline :label)
                               "")))
           ((plist-get inline :text))
           (t (or (etaf-md--inlines-text (plist-get inline :children))
                  ""))))
   inlines ""))

(defun etaf-md--block-text (block)
  "Return BLOCK's plain text."
  (or (plist-get block :text)
      (etaf-md--inlines-text (plist-get block :children))
      ""))

(defun etaf-md--item-text (item)
  "Return list ITEM's own line as plain text.
An item's first paragraph is its line; a nested list is carried by the item's
children instead of its text.  The inline runs spell the text without markup,
while the block's own :text keeps the source' backticks and asterisks."
  (let ((paragraph
         (seq-find (lambda (child) (eq (plist-get child :type) 'paragraph))
                   (plist-get item :children))))
    (if paragraph
        (or (etaf-md--inlines-text (plist-get paragraph :children))
            (etaf-md--block-text paragraph))
      "")))

(defun etaf-md--list-item-nodes (items depth)
  "Return ITEMS as child nodes at DEPTH.
The flat item list the parser hands back becomes one node per item, so a
container that lays its body out one line at a time reads the line and its
nesting instead of guessing from the source."
  (cl-loop
   for item in items
   collect
   (etaf-md-node-create
    :type 'list-item
    :attrs (list :text (etaf-md--item-text item) :depth depth)
    :block item
    :children
    (cl-loop
     for child in (plist-get item :children)
     when (eq (plist-get child :type) 'list)
     append (etaf-md--list-item-nodes (plist-get child :items) (1+ depth))))))

(defun etaf-md--table-row-nodes (rows aligns header)
  "Return table ROWS as child nodes, the HEADER row marked.
ALIGNS gives each cell of a row its alignment."
  (cl-loop
   for row in rows
   for index from 0
   collect
   (etaf-md-node-create
    :type 'table-row
    :attrs (list :header (and header (zerop index)))
    :children
    (cl-loop
     for cells in row
     for align in aligns
     collect (etaf-md-node-create
              :type 'cell
              :attrs (list :text (etaf-md--inlines-text cells)
                           :align align)
              :block (list :type 'paragraph :children cells
                           :text (etaf-md--inlines-text cells)))))))

(defun etaf-md--node-for-block (block)
  "Return BLOCK as a node, or nil for a block that paints no content.
A container node's type is the name the document wrote, so its definition is
found exactly as `etaf-md-define-node' registered it.  A list block and a
table block carry their items and rows as child nodes, which is the structure
a collection container reads; the block itself still paints through the shared
renderer when nothing overrides it."
  (pcase (plist-get block :type)
    ('container
     (etaf-md-node-create
      :type (intern (plist-get block :name))
      :attrs (plist-get block :attrs)
      :children (delq nil (mapcar #'etaf-md--node-for-block
                                  (plist-get block :children)))
      :source (plist-get block :source)
      :block block))
    ('list
     (etaf-md-node-create
      :type 'list
      :block block
      :children (etaf-md--list-item-nodes (plist-get block :items) 0)))
    ('table
     (etaf-md-node-create
      :type 'table-block
      :block block
      :children (etaf-md--table-row-nodes
                 (cons (plist-get block :header) (plist-get block :rows))
                 (plist-get block :aligns) t)))
    ('code-block
     (etaf-md-node-create
      :type 'code-block
      :attrs (list :language (plist-get block :lang))
      :block block))
    (_ (etaf-md-node-create :type (plist-get block :type) :block block))))

(defun etaf-md--block-needs-width-p (block)
  "Return non-nil when BLOCK's own VDOM depends on available column width.
Plain prose blocks (`paragraph', `heading', `list', `blockquote', `code-block')
without nested tables or figures let Ebox reflow them from the outer reading
measure without rebuilding their VDOM on resize."
  (when (listp block)
    (let ((type (plist-get block :type)))
      (cond
       ((eq type 'table) t)
       ((etaf-md--figure-block-p block) t)
       ((eq type 'blockquote)
        (cl-some #'etaf-md--block-needs-width-p (plist-get block :children)))
       ((eq type 'list)
        (cl-some (lambda (item)
                   (cl-some #'etaf-md--block-needs-width-p
                            (plist-get item :children)))
                 (plist-get block :items)))
       (t nil)))))

(defun etaf-md--container-view (session env block &optional slot)
  "Return the view BLOCK's definition gives it, under SESSION and ENV.
SLOT is the stable block slot symbol so container state survives edits above
the container.  Leaves `:width' nil so `etaf-md-available-width' resolves
lazily and containers that never query width skip resize re-renders."
  (let* ((node (etaf-md--node-for-block block))
         (paint-env (etaf-md-env-create
                     :session session
                     :node node
                     :width nil
                     :palette (plist-get env :palette)
                     :theme (plist-get env :theme)
                     :block block
                     :slot slot
                     :root-begin (plist-get block :begin))))
    (etaf-md--paint node paint-env)))

(defun etaf-md--heading-ref (id)
  "Return the host ref symbol naming the heading box with anchor ID."
  (when (and (stringp id) (not (string-empty-p id)))
    (intern (format "etaf-md-heading-%s" id))))

(defun etaf-md--wrap-heading (block view)
  "Attach a host ref to VIEW when BLOCK is a heading with an anchor id."
  (let ((ref (and view
                  (eq (plist-get block :type) 'heading)
                  (etaf-md--heading-ref (plist-get block :id)))))
    (if ref
        (etaf-node 'box (list :ref ref :width 'stretch) (list view))
      view)))

(defun etaf-md--wrap-block-width (block view session env)
  "Center wide BLOCK (table or figure) at SESSION's prose or wide figure budget.
Prose blocks already live inside a shared measured run wrapper owned by
`etaf-md--view-document', so returning VIEW directly avoids subscribing every
prose block Component to `:width'."
  (when view
    (let ((type (plist-get block :type)))
      (cond
       ((eq type 'table)
        (etaf-node 'column
                   (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
                   (list view)))
       ((etaf-md--figure-block-p block)
        (let* ((width (etaf-md--read session :width))
               (locked (plist-get env :width-locked))
               (figure (or (plist-get env :figure-width) width))
               (cell-width (or (plist-get (ignore-errors (etaf-display-metrics)) :char-width)
                               (frame-char-width)))
               (cap (if locked width (max width figure))))
          (etaf-node 'column
                     (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
                     (list (etaf-md--measured-view cap cell-width view)))))
       (t view)))))

(etaf-define-component etaf-md-block (&key session slot cell)
  "Render one published markdown block of SESSION owned by stable SLOT.
CELL is a per-block reactive `etaf-ref' holding the block's current AST.
Width-independent prose blocks read `etaf-md--base-env' so window resizes and
reading-measure adjustments never rebuild their VDOM subtrees."
  :render
  (let* ((block (etaf-value cell))
         (need-w (etaf-md--block-needs-width-p block))
         (raw-env (if need-w
                      (etaf-md--env session)
                    (etaf-md--base-env session)))
         (env (etaf-md--card-env session raw-env slot))
         (rendered
          (cond
           ((null block) nil)
           ((eq (plist-get block :type) 'container)
            (etaf-md--container-view session env block slot))
           ((etaf-md--block-empty-p block)
            (etaf-node 'text
                       (list :color (etaf-md--env-color env :muted)
                             :font-family (face-attribute 'fixed-pitch :family nil t))
                       (list (etaf-md--block-marker block))))
           ((eq (plist-get block :type) 'table)
            (let* ((table-max (if (plist-get env :width-locked)
                                  (plist-get env :width)
                                (or (plist-get env :figure-width)
                                    (plist-get env :width))))
                   (table-env (if table-max
                                  (plist-put (copy-sequence env) :table-max-width table-max)
                                env)))
              (etaf-ui-markdown-view-block block table-env)))
           (t (etaf-md--wrap-heading
               block (etaf-ui-markdown-view-block block env))))))
    (etaf-md--wrap-block-width block rendered session env)))

(defconst etaf-md--measure-gutter 2
  "Character cells kept blank on each side of the reading measure.
A window narrower than the measure fills the column, so centering alone
leaves no margin there and text would start on the window edge.  The gutter
is padding, so it survives that case, and it also keeps a table's right
border off the window's last column, where the renderer would extend its
paint into the sub-cell remainder.")

(defun etaf-md--raw-viewport-columns (session)
  "Return SESSION's current canvas/window width in columns, or nil."
  (let* ((buffer (plist-get session :buffer))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (canvas-cols (ignore-errors
                        (let* ((rt (or (etaf-current-runtime)
                                       (and (buffer-live-p buffer)
                                            (etaf-runtime-for-buffer buffer))))
                               (cols (and rt (etaf-runtime-mounted-p rt)
                                          (etaf-canvas-columns rt))))
                          (and (integerp cols) (> cols 0) cols)))))
    (or canvas-cols
        (and (window-live-p window) (window-body-width window))
        (etaf-md--read session :viewport-width))))

(defun etaf-md--page-widths (session width)
  "Return (MEASURE . FIGURE) columns for SESSION's page, capped at WIDTH.
MEASURE is the reading column: the session's cap, or the window when narrower.
FIGURE is the whole width the page may give a drawing or wide table, minus the
side gutters."
  (let* ((raw-cols (etaf-md--raw-viewport-columns session))
         (gutter etaf-md--measure-gutter)
         (available (if (and (integerp raw-cols) (> raw-cols 0))
                        (max 24 (- raw-cols (* 2 gutter)))
                      width)))
    (cons (min width available) available)))

(defun etaf-md--figure-block-p (block)
  "Return non-nil when BLOCK is drawn as its own picture."
  (pcase (plist-get block :type)
    ('code-block (equal (plist-get block :lang) "mermaid"))
    ('math (and (plist-get block :display) t))))

(defun etaf-md--block-view (session slot ref cell block trailing widths)
  "Return the keyed outer box + Component call for BLOCK under stable SLOT.
REF names the box that holds the block for scrolling and reverse-jump lookup.
TRAILING is the number of blank lines directly following BLOCK in the source,
rendered as `:margin-bottom' so blank lines never spawn separate Components.
WIDTHS is (MEASURE . FIGURE).  Placing `:key' directly on the outer box lets
ETAF match unchanged siblings in place when blocks are inserted or removed."
  (ignore block widths)
  (etaf-node 'box
             (append (list :key slot :ref ref :width 'stretch)
                     (when (and (integerp trailing) (> trailing 0))
                       (list :margin-bottom (list 'lh trailing))))
             (list (etaf-node 'etaf-md-block
                              (list :key slot :session session
                                    :slot slot :cell cell)
                              nil))))

(defun etaf-md--view-blocks (views)
  "Return keyed block VIEWS stacked inside one column."
  (etaf-node 'column
             (list :width 'stretch :cross-align 'center :item-gap '(lh 0))
             views))

;;; ---------------------------------------------------------------------------
;;; Media rendering
;;; ---------------------------------------------------------------------------

(defconst etaf-md--table-image-max-rows 16
  "Maximum character-row height for an image rendered inside a table cell.
Keeps tall portrait images legible while preserving multi-row table density.")

(defun etaf-md--table-image-view (node env)
  "Return the View of image NODE fitted inside its table cell in ENV.
Local images and cached remote images draw via the ETAF image Host without a
redundant figure border or caption; missing files and uncached remote URLs
fall back to the clickable inline image chip until available."
  (let* ((url (plist-get node :url))
         (alt (plist-get node :alt))
         (href (plist-get node :link))
         (remote (etaf-md--remote-url-p url))
         (cached-remote (and remote (etaf-md-cache-image-path url)))
         (path (cond (cached-remote cached-remote)
                     ((and (stringp url) (not remote))
                      (etaf-md--absolute-media url env))))
         (exists (and path (file-exists-p path)
                      (eq (etaf-md--media-kind path) 'image))))
    (if (not exists)
        (etaf-md--inline-image-view node env)
      (let* ((cell-width (max 4 (or (plist-get env :table-cell-width)
                                    (plist-get env :width)
                                    24)))
             (natural (etaf-md--image-pixels path))
             (pixels (etaf-md--media-target-pixels
                      natural (plist-get node :width) (plist-get node :height)))
             (grid (if (and (consp pixels)
                            (numberp (car pixels))
                            (numberp (cdr pixels)))
                       (etaf-md--media-grid-cells
                        pixels cell-width etaf-md--table-image-max-rows)
                     (cons (min cell-width 20) 8)))
             (cross (pcase (plist-get env :table-cell-align)
                      ('center 'center)
                      ('right 'end)
                      (_ 'start)))
             (label (if (and (stringp alt) (not (string-empty-p alt)))
                        alt
                      (or (file-name-nondirectory path) url "图片")))
             (open
              (if href
                  (lambda () (funcall (plist-get env :open-url) href))
                (lambda ()
                  (etaf-md--activate-media
                   env 'image path
                   (lambda ()
                     (let ((lb (plist-get env :open-lightbox)))
                       (unless (and (functionp lb)
                                    (funcall lb path alt))
                         (if (and (not remote) path)
                             (funcall (plist-get env :open-file) path)
                           (funcall (plist-get env :open-url) url))))))))))
        (etaf-node 'column
                   (list :width 'stretch
                         :cross-align cross
                         :margin '((lh 1) (ch 0))
                         :item-gap '(lh 0))
                   (list
                    (etaf-node 'image
                               (list :src path
                                     :columns (car grid)
                                     :rows (cdr grid)
                                     :adapter 'auto
                                     :on-press open
                                     :role (if href 'link 'button)
                                     :tab-index 0
                                     :pointer 'hand
                                     :help-echo (if href
                                                    (format "%s → %s" label href)
                                                  (format "%s（按 RET 放大/打开）" label)))
                               nil)))))))

(defun etaf-md--render-media (kind node env)
  "Return the media View for NODE of KIND in ENV.
Inline images render as a compact chip; table images render fitted inside
their table cell without redundant borders; block images, videos and HTML
media elements render as the full poster card with caption and activation."
  (pcase kind
    ('inline-image (etaf-md--inline-image-view node env))
    ('table-image (etaf-md--table-image-view node env))
    (_ (etaf-md--media-card (plist-get node :url)
                            (plist-get node :alt)
                            env kind
                            (plist-get node :width)
                            (plist-get node :height)))))

;;; ---------------------------------------------------------------------------
;;; Document
;;; ---------------------------------------------------------------------------

(defun etaf-md--measured-view (width cell-width view &optional key)
  "Return VIEW laid out in a reading column capped at WIDTH cells.
CELL-WIDTH is the canvas cell those columns resolve against.  Stretching inside
`:max-width' keeps prose centered at WIDTH in wide windows and wraps cleanly
inside the page gutters when the window narrows, without clipping."
  (etaf-node 'box
             (append (when key (list :key key))
                     (list :width 'stretch
                           :max-width (list 'px (* width cell-width))))
             (list view)))

(defun etaf-md--memoized-hero (session meta env)
  "Return memoized front-matter header box for META and ENV, or nil."
  (let ((cached (plist-get session :hero-cache)))
    (if (and cached (equal (car cached) meta) (eq (cadr cached) env))
        (cddr cached)
      (let* ((hero (and meta (etaf-md--meta-node (list :meta meta) env)))
             (node (when hero
                     (etaf-node 'box (list :key 'etaf-md-hero :width 'stretch)
                                (list hero)))))
        (plist-put session :hero-cache (cons meta (cons env node)))
        node))))

(defun etaf-md--memoized-footnotes (session footnotes env)
  "Return memoized footnotes column for FOOTNOTES and ENV, or nil."
  (let* ((fn-env
          (if (and footnotes
                   (cl-some (lambda (fn)
                              (cl-some #'etaf-md--block-needs-width-p
                                       (plist-get fn :children)))
                            footnotes))
              (etaf-md--env session)
            env))
         (cached (plist-get session :footnotes-cache)))
    (if (and cached (equal (car cached) footnotes) (eq (cadr cached) fn-env))
        (cddr cached)
      (let ((node (when footnotes
                    (etaf-node 'column
                               (list :width 'stretch :cross-align 'center
                                     :item-gap '(lh 0))
                               (append
                                (list (etaf-md--spacer)
                                      (etaf-md--divider "脚注")
                                      (etaf-md--spacer))
                                (etaf-ui-markdown-view-blocks
                                 footnotes (etaf-md--card-env
                                            session fn-env 'footnotes)))))))
        (plist-put session :footnotes-cache (cons footnotes (cons fn-env node)))
        node))))

(defun etaf-md--link-preview-card (session preview env)
  "Return the floating `etaf-dialog' peek view for active PREVIEW in SESSION."
  (let* ((title (or (plist-get preview :title) "预览"))
         (kind (plist-get preview :kind))
         (body (or (plist-get preview :body) ""))
         (open-fn (plist-get preview :on-open))
         (muted (etaf-md--env-color env :muted))
         (close-fn (lambda () (etaf-md--write session :link-preview nil))))
    (etaf-node
     'etaf-dialog
     (list :open t
           :title (if kind (format "%s · %s" title kind) title)
           :width '(ch 60)
           :compact t
           :close-label "关闭"
           :on-close close-fn
           :keys (list (list "K" close-fn "关闭链接预览")))
     (delq nil
           (list
            (etaf-node 'box (list :width 'stretch :max-height '(lh 8)
                                  :overflow 'scroll :wrap-mode 'word)
                       (list (etaf-node 'text (list :color muted) (list body))))
            (when (functionp open-fn)
              (etaf-node 'flex (list :width 'stretch :padding-top '(lh 1))
                         (list
                          (etaf-node 'etaf-button
                                     (list :label "打开目标 →"
                                           :variant 'primary
                                           :on-press
                                           (lambda ()
                                             (etaf-md--write session :link-preview nil)
                                             (funcall open-fn)))
                                     nil)))))))))

(defun etaf-md--lightbox-view (session lightbox)
  "Return `etaf-media-viewer' overlay View for active LIGHTBOX in SESSION."
  (let* ((items (plist-get lightbox :items))
         (count (length items))
         (idx (min (max 0 (or (plist-get lightbox :index) 0)) (max 0 (1- count))))
         (current (nth idx items)))
    (when current
      (let ((src (plist-get current :src))
            (caption (plist-get current :caption)))
        (etaf-node
         'etaf-media-viewer
         (list :open t
               :kind 'image
               :src src
               :source-size (etaf-md--image-pixels src)
               :title (or caption (file-name-nondirectory src))
               :subtitle (when (> count 1) (format "%d / %d" (1+ idx) count))
               :caption caption
               :on-close (lambda () (etaf-md--write session :lightbox nil))
               :on-previous (when (> count 1)
                              (lambda ()
                                (etaf-md--write
                                 session :lightbox
                                 (list :items items :index (mod (1- idx) count)))))
               :on-next (when (> count 1)
                          (lambda ()
                            (etaf-md--write
                             session :lightbox
                             (list :items items :index (mod (1+ idx) count))))))
         nil)))))

(defun etaf-md--measured-column (width cell-width views &optional key)
  "Return a centered column of VIEWS capped at WIDTH cells.
CELL-WIDTH is the canvas cell those columns resolve against.  Combining the
`:max-width' measure with the stacked column eliminates redundant wrapper boxes
across every prose run."
  (etaf-node 'column
             (append (when key (list :key key))
                     (list :width 'stretch
                           :max-width (list 'px (* width cell-width))
                           :cross-align 'center
                           :item-gap '(lh 0)))
             views))

(defun etaf-md--group-body-views (items block-views width cell-width)
  "Group consecutive prose blocks under shared measured columns.
Wide blocks (tables and display figures) stay directly in the centered body
column so they can break out across wide viewports while prose blocks share
coarse `:max-width' columns that update without waking prose Components."
  (if (null items)
      (when block-views
        (list (etaf-md--measured-column width cell-width block-views
                                        'etaf-md-run-default)))
    (let ((out nil)
          (run nil)
          (run-key nil))
      (cl-labels
          ((flush-run ()
             (when run
               (push (etaf-md--measured-column
                      width cell-width (nreverse run)
                      (format "etaf-md-run-%s" run-key))
                     out)
               (setq run nil run-key nil))))
        (dolist (item items)
          (pcase-let ((`(,slot ,wide-p ,view) item))
            (if wide-p
                (progn
                  (flush-run)
                  (push view out))
              (unless run-key (setq run-key slot))
              (push view run))))
        (flush-run))
      (nreverse out))))

(defun etaf-md--view-document (session structure env)
  "Return the reading View of SESSION's page STRUCTURE rendered in ENV.
STRUCTURE is a plist with `:meta', `:leading', `:items', `:views' and
`:footnotes'.  Every top-level block carries a stable `:key' on its outer box,
and hero, leading blank spacer and footnotes are keyed and memoized so
unrelated block edits never create spurious damage outside the edited block."
  (let* ((width (etaf-md--read session :width))
         (background (plist-get env :background))
         (meta (plist-get structure :meta))
         (leading (or (plist-get structure :leading) 0))
         (items (plist-get structure :items))
         (block-views (plist-get structure :views))
         (footnotes (plist-get structure :footnotes))
         (preview (etaf-md--read session :link-preview))
         (lightbox (etaf-md--read session :lightbox))
         (cell-width (or (plist-get (ignore-errors (etaf-display-metrics)) :char-width)
                         (frame-char-width)))
         (hero-box (etaf-md--memoized-hero session meta env))
         (leading-box
          (cond
           ((and (null block-views) (null hero-box))
            (etaf-node 'box
                       (list :key 'etaf-md-leading-blanks :width 'stretch
                             :height (list 'lh (max 1 leading)))
                       (list (etaf-node 'text nil (list " ")))))
           ((> leading 0)
            (etaf-node 'box
                       (list :key 'etaf-md-leading-blanks :width 'stretch
                             :height (list 'lh leading))
                       nil))))
         (chrome-views (append (when hero-box (list hero-box))
                               (when leading-box (list leading-box))))
         (fn-view (etaf-md--memoized-footnotes session footnotes env))
         (body-children (etaf-md--group-body-views items block-views width cell-width))
         (page-children
          (append
           (when chrome-views
             (list (etaf-md--measured-column width cell-width chrome-views
                                             'etaf-md-chrome)))
           (list (etaf-node 'column
                            (list :key 'etaf-md-body
                                  :width 'stretch
                                  :cross-align 'center
                                  :item-gap '(lh 0))
                            body-children))
           (when fn-view
             (list (etaf-md--measured-view width cell-width
                                           fn-view
                                           'etaf-md-footnotes)))))
         (overlays (delq nil
                         (list (when preview
                                 (etaf-md--link-preview-card session preview env))
                               (when lightbox
                                 (etaf-md--lightbox-view session lightbox)))))
         (reading-column
          (etaf-node 'column
                     (list :width 'stretch
                           :cross-align 'center
                           :padding (list (list 'lh 1)
                                          (list 'ch etaf-md--measure-gutter))
                           :item-gap '(lh 0)
                           :color (etaf-md--env-color env :ink))
                     page-children))
         (help-text "上下方向键按行滚动；TAB 切换链接与控件，RET 激活；T 开关目录侧窗，S 开关遮罩，K 预览光标处链接，? 查看快捷键。"))
    (etaf-node 'column
               (append (list :width '(vw 100) :cross-align 'center
                             :aria-label "Markdown 预览"
                             :help help-text
                             :on-direction
                             (lambda (direction)
                               (pcase direction
                                 ('down
                                  (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                    (etaf-scroll-viewport rt 1))
                                  'handled)
                                 ('up
                                  (when-let* ((rt (etaf-runtime-for-buffer (current-buffer))))
                                    (etaf-scroll-viewport rt -1))
                                  'handled)
                                 (_ 'release))))
                       (when background
                         (list :background-color background)))
               (cons reading-column overlays))))

(provide 'etaf-md-views)
;;; etaf-md-views.el ends here
