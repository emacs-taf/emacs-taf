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
(require 'etaf-md-theme)
(require 'etaf-md-env)

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
                  "  ·  "))
)
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
         (kind (etaf-md--media-kind target)))
    (etaf-node 'text
               (list :color (etaf-md--env-color env :accent)
                     :background-color (etaf-md--env-color env :accent-soft)
                     :role 'link :tab-index 0
                     :help-echo (or url alt)
                     :on-press (lambda ()
                                 (etaf-md--activate-media
                                  env kind target
                                  (lambda ()
                                    (funcall (plist-get env :open-url) url)))))
               (list (format "🖼 %s" alt)))))

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
  "Return non-nil when URL points to a remote resource."
  (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" url))

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
A vector states the size it should occupy.  Reading that costs a few hundred
bytes; asking the image loader for it rasterises the whole drawing instead, and
a diagram with filters takes seconds that way - a page paid it once per picture
every time it published."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (when (ignore-errors (insert-file-contents-literally path nil 0 4096))
      (goto-char (point-min))
      (when (re-search-forward "<svg\\b[^>]*>" nil t)
        (let* ((tag (match-string-no-properties 0))
               (width (and (string-match "\\bwidth=\"\\([0-9.]+\\)" tag)
                           (string-to-number (match-string 1 tag))))
               (height (and (string-match "\\bheight=\"\\([0-9.]+\\)" tag)
                            (string-to-number (match-string 1 tag)))))
          (and width height (> width 0) (> height 0) (cons width height)))))))

(defun etaf-md--probe-image-pixels (path)
  "Return PATH's image pixel size as (WIDTH . HEIGHT), or nil.
Drop PATH's entry first so an updated file is measured from its bytes rather
than the previous render."
  (if (string-suffix-p ".svg" (downcase path))
      (etaf-md--svg-declared-size path)
    (ignore-errors
      (clear-image-cache path)
      (when-let* ((image (create-image path nil nil)))
        (let ((size (image-size image t)))
          (cons (car size) (cdr size)))))))

(defun etaf-md--image-pixels (path)
  "Return PATH's pixel size as (WIDTH . HEIGHT), or nil.
Pixel measurement needs a graphic frame; a terminal frame renders the media
placeholder without probing.  Unchanged files reuse their cached probe."
  (when (display-graphic-p)
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

(defun etaf-md--media-grid-for-pixels (pixels max-columns)
  "Return the (COLUMNS . ROWS) grid for PIXELS capped by MAX-COLUMNS.
A picture whose size could not be read keeps a card of a fixed shape rather than
failing the whole page; `etaf-md--media-grid-cells' sizes a measured
one."
  (if (or (not (consp pixels))
          (not (numberp (car pixels)))
          (not (numberp (cdr pixels))))
      ;; A picture whose size could not be read keeps a card of a fixed shape
      ;; rather than failing the whole page.
      (cons (min max-columns 48) 14)
    (etaf-md--media-grid-cells pixels max-columns)))

(defun etaf-md--media-grid-cells (pixels max-columns)
  "Return the (COLUMNS . ROWS) grid for measured PIXELS inside MAX-COLUMNS.
A picture is drawn at its own size and scaled down as a whole only when it is
wider than the reading measure.  The width decides first, because that is the
side a page cannot grow: a picture that is whole cells wide, and a height that
follows from those columns, keeps the drawing inside the column it starts in.
Choosing the rows first and the columns from them rounded the height up to a
whole cell and handed back a picture up to a few percent wider than the
measure, which the window then cut off on the right."
  (let* ((cell (etaf-md--cell-metrics))
         (cell-width (car cell))
         (cell-height (cdr cell))
         (natural-width (float (car pixels)))
         (natural-height (float (cdr pixels)))
         (fitted (min natural-width (* max-columns cell-width)))
         (columns (max 1 (min max-columns (round (/ fitted cell-width)))))
         (fitted-height (* natural-height (/ (* columns cell-width) natural-width)))
         (rows (max 1 (round (/ fitted-height cell-height)))))
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
Only a local image has a size; a remote source and a missing file answer
nil, so a caller can size its card around the picture it will draw."
  (let* ((remote (etaf-md--remote-url-p url))
         (path (unless remote (etaf-md--absolute-media url env))))
    (when (and path (file-exists-p path)
               (eq (etaf-md--media-kind path) 'image))
      (etaf-md--media-grid-fit path max-columns max-rows))))

(defun etaf-md--media-picture (url env max-columns max-rows)
  "Return URL drawn as a plain picture for ENV inside MAX bounds.
No figure frame and no caption: the caller owns the card or the stage around
it.  A remote source becomes a placeholder that opens in the browser; a
missing file says so instead of failing the page."
  (let* ((remote (etaf-md--remote-url-p url))
         (path (unless remote (etaf-md--absolute-media url env)))
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
     ((and path (not exists))
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
         (path (unless remote (etaf-md--absolute-media url env)))
         (kind (and path (if (eq declared-kind 'video)
                             'video
                           (etaf-md--media-kind path))))
         (media-kind (or kind
                         (if (eq declared-kind 'video)
                             'video
                           (etaf-md--media-kind url))))
         (target (or path url))
         (exists (and path (file-exists-p path)))
         (open (if (and path exists)
                   ;; Local media opens with the operating system's default
                   ;; application, so a video plays instead of appearing as a
                   ;; binary buffer; remote and missing targets keep the URL
                   ;; callback.
                   (lambda ()
                     (etaf-md--activate-media
                      env media-kind path
                      (lambda () (funcall (plist-get env :open-file) path))))
                 (lambda ()
                   (etaf-md--activate-media
                    env media-kind target
                    (lambda () (funcall (plist-get env :open-url) url))))))
         (columns (plist-get env :width))
         (caption (or alt (and path (file-name-nondirectory path)) url))
         (help-label (if (and (stringp caption) (not (string-empty-p caption)))
                         caption
                       (or (and path (file-name-nondirectory path)) url))))
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
          (etaf-node 'column
                     (list :width 'stretch :cross-align 'center :item-gap '(lh 0)
                           :on-press open :role 'button :tab-index 0
                           :pointer 'hand
                           :help-echo (format "%s（按 RET 播放）" caption))
                     (list
                      (etaf-node 'box
                                 (list :border (list '(px 1) 'solid
                                                     (etaf-md--env-color env :border)))
                                 (list poster))
                      (etaf-md--caption-view
                       (format "▶ %s　·　按 RET 播放" caption)
                       env))))
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

(declare-function etaf-md--env "etaf-md-model" (session))
(declare-function etaf-md--block-marker "etaf-md-model" (block))
(declare-function etaf-md--block-empty-p "etaf-md-model" (block text))
(declare-function etaf-md--session-text "etaf-md-model" (session))
(declare-function etaf-md--card-env "etaf-md-model" (session env scope))

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

(defun etaf-md--container-view (session env block)
  "Return the view BLOCK's definition gives it, under SESSION and ENV.
A container whose name has no definition shows its source and one line saying
so; that block alone degrades and the rest of the page renders."
  (let* ((node (etaf-md--node-for-block block))
         (paint-env (etaf-md-env-create
                     :session session
                     :node node
                     :width (plist-get env :width)
                     :palette (plist-get env :palette)
                     :theme (plist-get env :theme)
                     :block block)))
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

(etaf-define-component etaf-md-block (&key session identity block)
  "Render one published markdown BLOCK of SESSION under IDENTITY.
The Component owns one block's hosts, and reads the session's environment in
its own render.  Publishing another block, or a new value for this one,
therefore replaces only the changed block's output: a block whose published
call is unchanged never renders again, so its Scope, hosts and video handles
stay."
  :render
  (let ((env (etaf-md--card-env session
                                        (etaf-md--env session)
                                        identity)))
      ;; A block whose text is gone paints nothing, so the page would show a
      ;; gap where its marker still lives in the source.  Showing the marker
      ;; there is what lets a reader see what is left and type it back.
      (let ((text (etaf-md--session-text session)))
        (cond
         ;; A blank source line renders nothing at all, yet it is a line a
         ;; reader types on.  One empty cell per blank line is enough for the
         ;; caret to stand there, and one row per line keeps every source
         ;; offset and its painted cell in step.
         ((eq (plist-get block :type) 'container)
          (etaf-md--container-view session env block))
         ((eq (plist-get block :type) 'blank)
          (etaf-node 'column nil
                     (make-list (max 1 (or (plist-get block :lines) 1))
                                (etaf-node 'text nil (list " ")))))
         ((etaf-md--block-empty-p block text)
          (etaf-node 'text
                     (list :color (etaf-md--env-color env :muted)
                           :font-family (face-attribute 'fixed-pitch :family nil t))
                     (list (etaf-md--block-marker block))))
         (t (etaf-md--wrap-heading
             block (etaf-ui-markdown-view-block block env)))))))

(defun etaf-md--page-widths (session width)
  "Return (MEASURE . FIGURE) columns for SESSION's page, capped at WIDTH.
MEASURE is the reading column: the session's cap, or the window when it is
narrower.  FIGURE is the whole width the page may give a drawing, which is the
window itself: a diagram's own size is what decides how large it is drawn, and
confining it to the prose measure shrank a wide one to half its type size."
  (let* ((buffer (plist-get session :buffer))
         (window (and (buffer-live-p buffer) (get-buffer-window buffer t)))
         (gutter etaf-md--measure-gutter)
         (available (if (window-live-p window)
                        (max 24 (- (window-body-width window) (* 2 gutter)))
                      width)))
    (cons (min width available) available)))

(defun etaf-md--figure-block-p (block)
  "Return non-nil when BLOCK is drawn as its own picture."
  (pcase (plist-get block :type)
    ('code-block (equal (plist-get block :lang) "mermaid"))
    ('math (and (plist-get block :display) t))))

(defun etaf-md--block-view (session key block ref widths)
  "Return the keyed Component call that renders BLOCK of SESSION under KEY.
WIDTHS is (MEASURE . FIGURE), the two widths the page lays out with.
REF names the box that holds the block, so a command can map the point back to
the block under it.  A published block keeps this call, so re-rendering the
list hands the runtime the unchanged value and costs one comparison per
retained block."
  (etaf-node 'box
             (list :ref ref :width 'stretch
                   ;; A drawing may use the whole page; prose fills the
                   ;; measured column it sits in, so it starts on the same
                   ;; edge as the page header above it.
                   :max-width (when (etaf-md--figure-block-p block)
                                (list 'ch (cdr widths))))
             (list (etaf-node 'etaf-md-block
                              (list :key key :session session :identity key
                                    :block block)
                              nil))))

(defun etaf-md--view-blocks (entries)
  "Return published ENTRIES as one keyed block Component each.
Blocks are stacked without a gap of the layout's own: the blank lines the file
holds between them are painted as empty rows, so the page keeps exactly the
lines the source has and a reader can type on each of them."
  (etaf-node 'column
             (list :width 'stretch :cross-align 'center)
             (mapcar (lambda (entry) (plist-get entry :view)) entries)))

;;; ---------------------------------------------------------------------------
;;; Media rendering
;;; ---------------------------------------------------------------------------

(defun etaf-md--render-media (kind node env)
  "Return the media View for NODE of KIND in ENV.
Inline images render as a compact chip; block images, videos and HTML media
elements render as the full poster card with caption and activation."
  (pcase kind
    ('inline-image (etaf-md--inline-image-view node env))
    (_ (etaf-md--media-card (plist-get node :url)
                            (plist-get node :alt)
                            env kind
                            (plist-get node :width)
                            (plist-get node :height)))))

;;; ---------------------------------------------------------------------------
;;; Document
;;; ---------------------------------------------------------------------------


(defconst etaf-md--measure-gutter 2
  "Character cells kept blank on each side of the reading measure.
A window narrower than the measure fills the column, so centering alone
leaves no margin there and text would start on the window edge.  The gutter
is padding, so it survives that case, and it also keeps a table's right
border off the window's last column, where the renderer would extend its
paint into the sub-cell remainder.")

(defun etaf-md--measured-view (width cell-width view)
  "Return VIEW laid out in a reading column WIDTH cells wide.
CELL-WIDTH is the canvas cell those columns resolve against.  The width is
stated rather than left to stretch and a maximum: the header and the body are
two children of the page's centring column, and a stretched child with a max
width settled on a different left edge from the other."
  (etaf-node 'box (list :width (list 'px (* width cell-width)))
             (list view)))

(defun etaf-md--view-document (session document env)
  "Return the reading View of DOCUMENT, shown by SESSION, rendered in ENV.
The body is one keyed Component per published block, so a publish that
changes one block repaints that block instead of the document.  The page
takes the window's width and centres its children; prose states ENV's
reading measure, and a drawing states the page's whole width, so a wide one
keeps its type size instead of being squeezed into a column of text.  ENV's
`:background', when set, paints the page; without it the buffer keeps the
Emacs theme's own background."
  (let* (;; The blocks state their own measure from the session, so the page
         ;; must read the same number: taking ENV's window width here made the
         ;; header a few columns wider than the body, and centring split the
         ;; difference into an indent the body did not have.
         (width (car (etaf-md--page-widths
                      session (etaf-md--read session :width))))
         (background (plist-get env :background))
         (hero (etaf-md--meta-node document env))
         ;; One read for the whole page: the reading column and the picture
         ;; cells both state pixels, and both must use the canvas's own cell.
         (cell-width (or (plist-get (ignore-errors (etaf-display-metrics)) :char-width)
                         (frame-char-width)))
         (measured (lambda (view) (etaf-md--measured-view width cell-width view)))
         (entries (if hero
                      (cons (list :view (etaf-node 'box
                                                   (list :width 'stretch)
                                                   (list hero)))
                            (plist-get document :children))
                    (plist-get document :children)))
         (body (append
                (list (funcall measured (etaf-md--view-blocks entries)))
                (when-let* ((footnotes (plist-get document :footnotes)))
                  (list (funcall measured
                                 (etaf-node 'column
                                            (list :width 'stretch :cross-align 'center
                                                  :item-gap '(lh 0))
                                            (append
                                             (list (etaf-md--spacer)
                                                   (etaf-md--divider "脚注")
                                                   (etaf-md--spacer))
                                             (etaf-ui-markdown-view-blocks
                                              footnotes (etaf-md--card-env
                                                         session env 'footnotes))))))))))
    (etaf-node 'column
               (append (list :width '(vw 100) :cross-align 'center
                             :aria-label "Markdown 预览"
                             :help "链接和图片可直接激活；视频在文档内播放，缺少解码器时使用系统播放器。")
                       (when background
                         (list :background-color background)))
               (list
                ;; The page is as wide as the window.  Prose states the reading
                ;; measure and is centred in it; a drawing states the whole
                ;; width, so a wide one is not squeezed into a column of text.
                (etaf-node 'column
                           (list :width 'stretch
                                 :cross-align 'center
                                 :padding (list (list 'lh 1)
                                                (list 'ch etaf-md--measure-gutter))
                                 :item-gap '(lh 0)
                                 :color (etaf-md--env-color env :ink))
                           body)))))

(provide 'etaf-md-views)
;;; etaf-md-views.el ends here
