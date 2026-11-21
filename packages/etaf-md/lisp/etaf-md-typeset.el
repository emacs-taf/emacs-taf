;;; etaf-md-typeset.el --- Draw diagrams and formulas with a program  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Two block kinds carry a picture rather than prose: a fenced `mermaid' block
;; and a `$$' display formula.  The parser and the shared renderer keep them as
;; source, which is what a reader sees when nothing else is installed.  When
;; mermaid-cli is present this module draws them: the diagram through `mmdc',
;; the formula through KaTeX and the Chromium mmdc already brings.
;;
;; A render is asynchronous and cached by what it depends on, so a repaint of
;; the same block costs one file check.  Until the picture exists the block
;; keeps its source, and a finished render repaints the page in place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'json)
(require 'etaf-md-model)
(require 'etaf-md-views)

(declare-function image-size "image.c" (spec &optional pixels frame))

(defgroup etaf-md-typeset nil
  "Diagrams and display formulas drawn by an external program."
  :group 'etaf-md)

(defcustom etaf-md-typeset t
  "Whether the preview draws a diagram and a display formula with a program.
When nil, or when mermaid-cli is not installed, a mermaid block and a display
formula keep the source and the plain-text rendering the shared renderer
paints.  A page never waits for a program either way: a picture that is not
cached yet appears on the repaint that follows its render."
  :type 'boolean)

(defconst etaf-md-typeset--cache-directory
  (expand-file-name "etaf-md/typeset/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Directory holding one PNG per rendered block.")

(defconst etaf-md-typeset--scale 2
  "Pixels per point a picture is drawn at, so it stays sharp when it is placed.")

(defconst etaf-md-typeset--formula-scale 1.0
  "A display formula is set at the page's body size.
A formula is part of the text around it, so it takes the reader's own body
size; KaTeX adds the air a fraction, a sum or an integral needs above and
below the line on its own.")

(defun etaf-md--typeset-pixels ()
  "Return the pixel size to typeset a formula at.
The page's body size comes from the frame's own default font, so a reader who
changes their font size gets a formula that still matches the text."
  (max 12 (round (* (etaf-md--base-pixels)
                    etaf-md-typeset--formula-scale))))

(defvar etaf-md-typeset--running (make-hash-table :test #'equal)
  "Render in flight by block key, so one block never renders twice.")

(defvar etaf-md-typeset--missing nil
  "Non-nil once the programs were looked for and not found.")

(defconst etaf-md-typeset--renderer-idle 45
  "Seconds the drawing program may idle before it is stopped.
Chromium costs memory while it runs and a page draws its pictures once, so an
editor that stopped reading diagrams should not keep a browser around.")

(defvar etaf-md-typeset--renderer nil
  "The drawing program's process, or nil before the first picture.")

(defvar etaf-md-typeset--renderer-text ""
  "Answers received from the renderer that do not make a whole line yet.")

(defvar etaf-md-typeset--requests (make-hash-table)
  "Render in flight by request id.
Each entry is a plist of `:key', `:kind', `:path' and `:done'.")

(defvar etaf-md-typeset--serial 0
  "Number of the last request handed to the renderer.")

(defvar etaf-md-typeset--idle-timer nil
  "Timer that stops the renderer when it has nothing left to draw.")

(defvar etaf-md-typeset--failed (make-hash-table :test #'equal)
  "Renderer's message by block key of a block that cannot be drawn.
A key holds the source and every setting the picture depends on, so a block
stays unrendered until its source or the page changes, and one bad diagram is
not retried on every keystroke that republishes the page.")

(defun etaf-md-typeset--renderer-script ()
  "Return the drawing program's path, or nil when this checkout lacks it."
  (when-let* ((entry (locate-library "etaf-md"))
              ((not (string-suffix-p ".eln" entry)))
              (script (expand-file-name "scripts/mermaid-render.mjs"
                                        (file-name-directory entry)))
              ((file-exists-p script)))
    script))

(defun etaf-md-typeset-available-p ()
  "Return non-nil when this system can draw diagrams and formulas.
Both are drawn by `scripts/mermaid-render.mjs', which needs Node and the
mermaid-cli package beside `mmdc': the diagram is mermaid's own renderer and
the formula is KaTeX on the Chromium mmdc brings."
  (and etaf-md-typeset
       (not etaf-md-typeset--missing)
       (or (and (executable-find "mmdc")
                (executable-find "node")
                (etaf-md-typeset--renderer-script))
           ;; Answer nil the first time too: the fallback used to return the
           ;; setq's value, so the page asked for a render on a machine that
           ;; has no renderer and then waited on programs that never help.
           (progn (setq etaf-md-typeset--missing t) nil))))

(defun etaf-md--typeset-colors (env)
  "Return (PALETTE . INK) drawn for ENV's page.
The diagram theme follows the page it is placed on, which a named palette sets
even when the frame is the other way round: a light page keeps light diagrams.
A page with no background of its own is read from its palette's surface, the
same value the page paints, so a picture and its page never disagree about
which way round they are.  A formula is inked in the page's own text colour, so
both sit on whatever surface the page paints instead of carrying a palette of
their own."
  (let* ((background (or (plist-get env :background)
                         ;; A page in the face-derived appearance has no
                         ;; background of its own, but its palette still names
                         ;; the surface it paints: the frame's appearance is a
                         ;; second opinion, and the two disagree whenever a
                         ;; theme's faces are lighter than `background-mode'
                         ;; says.  A picture drawn from the frame's opinion
                         ;; lands as light ink on a light page.
                         (etaf-md--env-color env :bg)))
         ;; The surface is dark when it stands farther from white than from
         ;; black.  A fixed ratio against black called a slate page light: the
         ;; palette's #191a1c sits 1.6:1 from black, past the 1.5 the old test
         ;; asked for, so a dark page was drawn with the light palette.
         (dark (> (etaf-ui-color-contrast background "#ffffff")
                  (etaf-ui-color-contrast background "#000000"))))
    (cons (if dark 'dark 'light)
          (etaf-md--hex-color (etaf-md--env-color env :ink)))))

(defconst etaf-md-typeset--picture-version 5
  "Version of the drawing a cache key stands for.
Raised when the renderer's own output changes - the size a picture is drawn
at, or the part of the drawing it is cut from - so a picture drawn the old way
is drawn again instead of being reused as if it were the new one.")

(defun etaf-md--typeset-page (env)
  "Return ENV's page constants for a picture key: (COLORS . CONFIG-HASH).
The configuration of a diagram is generated from the page's colours and type
size, which is the same answer for every block of that page and costs more
than the rest of a publish.  It is built once and reused while those inputs
hold; the signature is compared rather than assumed, because a page can be
published again after the reader changed the frame's font."
  (let ((signature (list (plist-get env :theme)
                         (plist-get env :background)
                         (plist-get env :ink)
                         (etaf-md--base-pixels))))
    (let ((cached (plist-get env :typeset-page)))
      (if (and cached (equal (car cached) signature))
          (cdr cached)
        (let ((page (cons (etaf-md--typeset-colors env)
                          (secure-hash 'sha1 (etaf-md--mermaid-config env)))))
          (plist-put env :typeset-page (cons signature page))
          page)))))

(defun etaf-md--typeset-key (kind source env)
  "Return the cache key of KIND drawn from SOURCE for ENV's surface.
The key holds what the picture depends on, so a theme switch draws a new one
instead of reusing the colours of the old surface."
  (let* ((page (etaf-md--typeset-page env))
         (colors (car page)))
    (secure-hash 'sha1
               (format "%s\n%d\n%s\n%s\n%s\n%s"
                       kind etaf-md-typeset--picture-version source
                       (car colors)
                       (cdr colors)
                       ;; A formula drawn for another body size is another
                       ;; picture, not a cache hit.
                       ;; A formula depends on the size it is set at, and a
                       ;; diagram on every setting of the renderer's config:
                       ;; the font it is measured with, its colours and its
                       ;; margins.  A key without them hands back a picture
                       ;; drawn the old way, which is how a font change looked
                       ;; like it had not been applied.
                       (if (eq kind 'math)
                           (format "%d/%d"
                                   (etaf-md--typeset-pixels)
                                   (cdr (etaf-md--cell-metrics)))
                         (cdr page))))))

(defun etaf-md--typeset-path (key)
  "Return the PNG path of KEY."
  (expand-file-name (concat key ".png") etaf-md-typeset--cache-directory))

(defun etaf-md--typeset-picture (key)
  "Return the picture drawn for KEY, or nil when it is not drawn yet.
A diagram has a vector copy beside its raster, which every place the picture is
shown prefers: it stays sharp at whatever size the page gives it and holds no
bitmap in memory.  A formula is drawn as a raster only.  The raster is the
marker of a finished render either way, because it is written first."
  (when-let* ((raster (etaf-md--typeset-path key))
              ((file-exists-p raster)))
    (let ((vector (concat (file-name-sans-extension raster) ".svg")))
      (if (file-exists-p vector) vector raster))))

(defun etaf-md-typeset-attach (block env)
  "Return BLOCK carrying the picture already rendered for it in ENV.
The block gains `:picture', the PNG path, when one exists; the renderer draws
that and leaves a block without one as its source.  Publishing compares the
block's content, so a picture that arrived makes the block different and the
page paints it without any other bookkeeping.  Reading the cache is all this
does: a render never starts a program, because a render is also the pass a
keystroke pays for."
  (let ((kind (pcase (plist-get block :type)
                ('code-block (and (equal (plist-get block :lang) "mermaid") 'mermaid))
                ('math (and (plist-get block :display) 'math)))))
    (if (not kind)
        block
      (if-let* ((source (plist-get block :text))
                ((not (string-blank-p source)))
                ;; A picture already on disk is shown whether or not this system
                ;; can draw new ones: a preview that once drew diagrams must not
                ;; lose them because the drawing program went missing later.
                (path (etaf-md--typeset-picture
                       (etaf-md--typeset-key kind source env))))
          (plist-put (copy-sequence block) :picture path)
        block))))

(defun etaf-md--typeset-figure (kind path env)
  "Return the View of the picture at PATH for KIND in ENV.
A diagram keeps a caption that opens the file, the way an image card does; a
formula is its own line with no frame, because it belongs to the sentence above
it.  The figure states the reading measure as its own width instead of filling
its container: a block is a Component, and a stretch inside one resolves against
the frame rather than the page, which left a figure centred for the frame and
clipped by the page."
  (let* (;; A drawing may use the page's whole width: its own size decides how
         ;; large it is painted, and the reading measure would shrink a wide
         ;; one to half its type size.
         (width (max 24 (or (plist-get env :figure-width)
                            (plist-get env :width) 92)))
         ;; The picture is drawn at `--scale' device pixels per point, so its
         ;; own pixel size is that many times the size it should occupy; the
         ;; grid it is placed in comes from the size on the page, not the file.
         (pixels (when-let* ((natural (ignore-errors
                                        (etaf-md--image-pixels path))))
                   (cons (/ (car natural) (float etaf-md-typeset--scale))
                         (/ (cdr natural) (float etaf-md-typeset--scale)))))
         (grid (or (etaf-md--media-grid-for-pixels pixels (- width 2))
                   (cons width 8)))
         ;; A zoom changes the grid, and a vector drawn to the new size costs a
         ;; whole rasterisation: librsvg paints gradients and component
         ;; transfers, roughly eighty milliseconds a drawing, and a page
         ;; measures every slice it holds.  The raster beside the vector is
         ;; the same drawing at twice the size it is shown at, so while it
         ;; still has the pixels a zoom needs, it is shown instead: loading it
         ;; is a decode, not a drawing.  A grid that outgrows it goes back to
         ;; the vector, which stays sharp at any size.
         (raster (concat (file-name-sans-extension path) ".png"))
         (shown (if (and (string-suffix-p ".svg" path)
                         (file-exists-p raster)
                         (when-let* ((declared (ignore-errors
                                                 (etaf-md--image-pixels raster))))
                           (<= (* (car grid) (car (etaf-md--cell-metrics)))
                               (car declared))))
                    raster
                  path))
         (image (etaf-node 'image
                           (list :src shown
                                 :columns (car grid)
                                 :rows (cdr grid)
                                 :adapter 'auto)
                           nil)))
    (if (eq kind 'math)
        ;; A formula is a line of the text around it: the raster carries the
        ;; transparent rows that centre it in whole rows, and the source's own
        ;; blank lines are what separate it from the blocks beside it.  Block
        ;; padding would add whole lines, since a fractional line of padding
        ;; still takes one, and that turned two formulas one blank line apart
        ;; into an 80-pixel gap.
        (etaf-node 'column
                   (list :width 'stretch :max-width (list 'ch width)
                         :cross-align 'center)
                   (list image))
      (let ((open-file (plist-get env :open-file))
            (caption (format "%s（按 RET 打开）" (file-name-nondirectory path))))
        ;; A diagram is its own drawing: no frame around it, and the caption
        ;; under it names the file, so the page reads as one surface instead of
        ;; a card inside a card.
        (etaf-node 'column
                   (list :width 'stretch :max-width (list 'ch width)
                         :cross-align 'center :item-gap '(lh 0)
                         :on-press (lambda ()
                                     (etaf-md--activate-media
                                      env 'image path
                                      (lambda ()
                                        (when open-file
                                          (funcall open-file path)))))
                         :role 'button :tab-index 0 :pointer 'hand
                         :help-echo caption)
                   (list image
                         (etaf-md--caption-view "▲ mermaid" env)))))))

(defconst etaf-md-mermaid-fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Families a diagram falls back to when the reader's own font lacks a glyph.
The WenKai faces carry the CJK shapes a diagram label needs, spelled the way the
font names itself: `LXGWWenKai' is the file's name, not its family, and a family
the renderer cannot find falls back to whatever CJK face the system picks.
The rest are families every desktop has, so a label is always measurable.")

(defun etaf-md--mermaid-font-family ()
  "Return the font stack a diagram is drawn and measured with.
The reader's default face comes first, so a diagram uses the type they read
the page in; the names after it cover the glyphs that face may lack."
  (let* ((family (ignore-errors (face-attribute 'default :family nil t)))
         (names (if (and (stringp family)
                         (not (string-empty-p family))
                         ;; A face may name the symbol `default', which is not a
                         ;; family the renderer can find.
                         (not (string= family "default")))
                    (cons family etaf-md-mermaid-fonts)
                  etaf-md-mermaid-fonts)))
    (mapconcat #'identity (delete-dups names) ", ")))

(defconst etaf-md--mermaid-hues
  '(:accent :ok :warn :important :danger :muted)
  "Theme colors a diagram takes its categorical series from.
Mermaid separates a git graph's branches, a pie's slices, a timeline's periods
and a mind map's children by hue.  These are the page's own callout colors, in
the order it introduces them, so a diagram never brings in a hue the page does
not already use.")

(defconst etaf-md--mermaid-fill-contrast 3.0
  "Contrast ratio a diagram's label keeps against the fill under it.
Three to one is the floor for drawn text; the four and a half of body prose is
unreachable here, because the same colour is also the line that carries the
structure - a mind map's branch, a timeline's rule - and a fill dark enough to
carry the page's own dark ink on a dark page is a fill the page cannot see.")

(defconst etaf-md--mermaid-fill-separation 1.5
  "Contrast ratio a category fill keeps against the page it is drawn on.
A fill the colour of the page is not a fill, and mermaid paints a mind map's
branch and a timeline's rule in this same colour: a fill that only just stands
off the page leaves those lines too faint to follow.")

(defun etaf-md--mermaid-fill (page ink hue &optional label separate)
  "Return (FILL . LABEL) for HUE mixed into PAGE, and for the label on it.
A filled area has two jobs: it stands `etaf-md--mermaid-fill-separation'
away from PAGE so it reads as a shape, and the text on it reads at
`etaf-md--mermaid-fill-contrast'.  The page's own ink does not always
manage both - a saturated hue carries neither a dark ink nor a light one - so
the label falls back to the page colour when that reads better, and the mix is
the palest one that satisfies both.  LABEL states one colour for the text
instead, and SEPARATE `no' drops the demand to stand off the page, for a filled
area that carries its own border.  A hue that never satisfies them keeps the
mix that comes closest."
  (let ((best (cons (etaf-md--mix-color page hue 0.3) (or label ink)))
        (separate (not (eq separate 'no)))
        (best-score 0)
        (weight 0.15))
    (catch 'done
      (while (<= weight 0.95)
        (let* ((fill (etaf-md--mix-color page hue weight))
               (text (or label
                         (if (> (or (etaf-md--contrast-ratio page fill) 0)
                                (or (etaf-md--contrast-ratio ink fill) 0))
                             page ink)))
               (label-ratio (or (etaf-md--contrast-ratio text fill) 0))
               (page-ratio (or (etaf-md--contrast-ratio fill page) 0))
               (score (if separate
                          (min (/ label-ratio etaf-md--mermaid-fill-contrast)
                               (/ page-ratio etaf-md--mermaid-fill-separation))
                        (/ label-ratio etaf-md--mermaid-fill-contrast))))
          (when (> score best-score)
            (setq best (cons fill text) best-score score))
          (when (>= score 1.0)
            (throw 'done (cons fill text))))
        (setq weight (+ weight 0.05)))
      best)))

(defun etaf-md--page-colors (env)
  "Return ENV's page colours, keyed by role, as #rrggbb.
A theme may name a colour the way X11 does (`grey70'), and neither the
renderer's browser nor mermaid reads that name.  The page's colours are turned
into hex once here rather than at each place that draws with them, so no field
of the configuration can carry a name the renderer cannot parse."
  (let ((role (lambda (key)
                (etaf-md--hex-color (etaf-md--env-color env key)))))
    (list :ink (funcall role :ink)
          :panel (funcall role :panel)
          :panel2 (funcall role :panel2)
          :border (funcall role :border)
          :muted (funcall role :muted)
          :quote (funcall role :quote-bg)
          ;; A page in the face-derived appearance has no background of its
          ;; own; its palette still names the surface it paints.
          :page (etaf-md--hex-color
                 (or (plist-get env :background)
                     (etaf-md--env-color env :bg))))))

(defun etaf-md--mermaid-tint (page ink weight)
  "Return PAGE moved toward INK by WEIGHT.
A diagram needs surfaces one step away from the page - a cluster, a gantt's
section band, its grid - and a page whose panels are nearly its own color gives
no such step.  A tint of the page toward its ink is a step in the direction the
page is built in, so it stays a page surface in every palette."
  (etaf-md--mix-color page ink weight))

(defun etaf-md--mermaid-states (env page ink)
  "Return the surfaces a gantt paints a task's state with.
A gantt separates a finished task from a running one from a late one by
background: mermaid fills them with light grey, white and red, the colors of a
light page on any page.  The page already has a colour for each of those ideas,
so the state takes it, mixed into PAGE far enough for the task's own label."
  (let ((surface (lambda (key prefix)
                   (let* ((hue (etaf-md--hex-color
                                (etaf-md--env-color env key)))
                          ;; A bar carries its state at its edge, so its fill
                          ;; only has to hold the task's text.
                          (fill (car (etaf-md--mermaid-fill
                                      page ink hue ink 'no))))
                     (list (cons (intern (concat prefix "BkgColor")) fill)
                           (cons (intern (concat prefix "BorderColor")) hue))))))
    (append (funcall surface :ok "doneTask")
            (funcall surface :accent "activeTask")
            (funcall surface :danger "crit"))))

(defun etaf-md--mermaid-family-theme (env colors)
  "Return the theme variables that later diagram families read.
Each of these families paints its own surface - a chart's plot, a radar's disc,
a C4 box - instead of deriving it from the box colour, so the page states the
surface and the ink that goes on it for every family at once."
  (let ((page (plist-get colors :page))
        (ink (plist-get colors :ink))
        (border (plist-get colors :border))
        (muted (plist-get colors :muted))
        (panel (plist-get colors :panel))
        (quote-bg (plist-get colors :quote)))
    `((xyChart . ((backgroundColor . ,page)
                  (titleColor . ,ink)
                  (xAxisLabelColor . ,muted) (xAxisTitleColor . ,ink)
                  (xAxisTickColor . ,muted) (xAxisLineColor . ,border)
                  (yAxisLabelColor . ,muted) (yAxisTitleColor . ,ink)
                  (yAxisTickColor . ,muted) (yAxisLineColor . ,border)
                  (plotColorPalette . ,(etaf-md--mermaid-plot-colours env page ink))
                  (dataLabelColor . ,ink) (legendTextColor . ,ink)))
      ;; A radar's curves are strokes over a mostly empty disc, so its series
      ;; keep the hue rather than the fill mixed for a solid shape.
      (radar . ((axisColor . ,muted) (axisStrokeWidth . 1)
                (graticuleColor . ,(etaf-md--mermaid-tint page ink 0.14))
                (graticuleStrokeWidth . 1)
                (curveStrokeWidth . 2) (curveOpacity . 0.2)))
      (architecture . ((archEdgeColor . ,muted)
                       (archEdgeArrowColor . ,muted)
                       (archGroupBorderColor . ,border)))
      (c4 . ((personBkg . ,panel) (personBorder . ,border)
             (systemBkg . ,panel) (systemBorder . ,border)
             (externalSystemBkg . ,quote-bg)
             (externalSystemBorder . ,border)
             (messageTextColor . ,ink))))))

(defun etaf-md--mermaid-series (env page ink)
  "Return ENV's category colours, keyed by role.
:fill is a page surface carrying the page's own ink, :hue is the same colour
unmixed, for the line or border that belongs to the same category, and :label
is the ink that goes on the fill."
  (mapcar (lambda (key)
            (let* ((hue (etaf-md--hex-color
                         (etaf-md--env-color env key)))
                   (fill (etaf-md--mermaid-fill page ink hue)))
              (list :hue hue :fill (car fill) :label (cdr fill))))
          etaf-md--mermaid-hues))

(defun etaf-md--mermaid-plot-colours (env page ink)
  "Return a chart's series colours as a comma-separated list.
A bar is a filled shape, so it takes the surface that carries the page's ink;
the line beside it takes the hue itself, where the difference between the two
series has to be visible in a stroke a pixel wide."
  (let ((series (etaf-md--mermaid-series env page ink)))
    (mapconcat #'identity
               (cl-loop for index from 0 below 6
                        for entry = (nth (mod index (length series)) series)
                        ;; A bar is filled, so it takes the surface; the line
                        ;; beside it is a stroke and takes the hue itself.
                        collect (plist-get entry (if (cl-evenp index) :fill :hue)))
               ",")))

(defun etaf-md--mermaid-categorical (env page ink)
  "Return the theme variables that colour ENV's diagram categories.
Mermaid derives those colours by darkening the box color of the page, which on
a dark page leaves every slice, branch and period black, and it cannot tell a
dark page from a light one.  So the page's callout colors supply the hues, each
mixed into PAGE for the fill and kept as it is for the lines and borders that
carry the same category."
  (let* ((series (etaf-md--mermaid-series env page ink))
         (pick (lambda (index) (nth (mod index (length series)) series))))
    (append
     (cl-loop for i from 0 below 12
              for entry = (funcall pick i)
              for fill = (plist-get entry :fill)
              for label = (plist-get entry :label)
              for hue = (plist-get entry :hue)
              append (list (cons (intern (format "cScale%d" i)) fill)
                           (cons (intern (format "cScaleInv%d" i)) hue)
                           (cons (intern (format "cScalePeer%d" i)) hue)
                           (cons (intern (format "cScaleLabel%d" i)) label)
                           (cons (intern (format "pie%d" (1+ i))) fill)))
     (cl-loop for i from 0 below 8
              for entry = (funcall pick i)
              for fill = (plist-get entry :fill)
              for label = (plist-get entry :label)
              for hue = (plist-get entry :hue)
              append (list (cons (intern (format "git%d" i)) fill)
                           (cons (intern (format "gitInv%d" i)) hue)
                           (cons (intern (format "gitBranchLabel%d" i)) label)
                           ;; A journey paints a period's band and its tasks by
                           ;; the same series, and its actors beside them.
                           (cons (intern (format "fillType%d" i)) fill)
                           (cons (intern (format "actor%d" i)) hue))))))

(defun etaf-md--typeset-palette (env)
  "Return the page's colours as the drawing program names them.
A few diagram families write their own colours instead of reading a theme, so
the renderer is told the page's palette once and states it where those families
listen.  Naming the roles here keeps mermaid's vocabulary out of the renderer."
  (let ((colors (etaf-md--page-colors env)))
    (list :page (plist-get colors :page)
          :ink (plist-get colors :ink)
          :line (plist-get colors :muted)
          :panel (plist-get colors :panel)
          :danger (etaf-md--hex-color
                   (etaf-md--env-color env :danger)))))

(defun etaf-md--mermaid-config (env)
  "Return the mermaid configuration JSON drawn for ENV's page.
The diagram is built from the page's own colours instead of mermaid's fixed
`default' and `dark' palettes, so a light page carries light boxes with its own
ink, and the margins keep the drawing off the card's edges: without them a
sequence diagram starts at the very first pixel."
  (let* ((colors (etaf-md--page-colors env))
         (ink (plist-get colors :ink))
         (panel (plist-get colors :panel))
         (panel2 (plist-get colors :panel2))
         (border (plist-get colors :border))
         (muted (plist-get colors :muted))
         (quote-bg (plist-get colors :quote))
         (page (plist-get colors :page))
        ;; A frame supplies the body size; a batch run has none, and rounding
        ;; its answer would size every diagram at one pixel.
        (base (max 8 (round (etaf-md--base-pixels)))))
    (json-encode
     `((look . "classic")
       (theme . "base")
       ;; A label is text, not an HTML box: mermaid otherwise wraps every label
       ;; in the SVG's `foreignObject', which only a browser can draw, so the
       ;; picture shows its shapes and loses every word in any other renderer.
       (htmlLabels . :json-false)
       (themeVariables
        ;; Mermaid derives most of a drawing's own colours from this one:
        ;; given `transparent' it computes black, so a dark card, a radar disc
        ;; and a C4 canvas came out black on a light page.  The page's own
        ;; colour is both the honest answer and the one every derivation needs.
        . ((background . ,page)
           (primaryColor . ,panel)
           (primaryTextColor . ,ink)
           (primaryBorderColor . ,border)
           (secondaryColor . ,panel2)
           (secondaryTextColor . ,ink)
           (tertiaryColor . ,quote-bg)
           (tertiaryTextColor . ,ink)
           (lineColor . ,muted)
           (textColor . ,ink)
           (mainBkg . ,panel)
           (nodeBorder . ,border)
           ;; A cluster is a surface the nodes sit on, so it is a step from
           ;; the page rather than the page's quote colour, which is darker
           ;; than the page on a dark theme and swallowed the grouping.
           (clusterBkg . ,(etaf-md--mermaid-tint page ink 0.06))
           (clusterBorder . ,border)
           ;; An edge label sits on a solid chip so the line does not cross it.
           ;; The chip is the same step from the page as a cluster, so a label
           ;; inside a cluster does not cut a darker hole in it.
           (edgeLabelBackground . ,(etaf-md--mermaid-tint page ink 0.06))
           (actorBkg . ,panel)
           (actorBorder . ,border)
           (actorTextColor . ,ink)
           (signalColor . ,muted)
           (signalTextColor . ,ink)
           (labelBoxBkgColor . ,panel)
           (labelBoxBorderColor . ,border)
           (labelTextColor . ,ink)
           (noteBkgColor . ,quote-bg)
           (noteTextColor . ,ink)
           (noteBorderColor . ,border)
           ;; A slice is separated from the next by the page itself, and the
           ;; outer ring is the page's border, so a pie reads as sections of
           ;; one drawing instead of sections inside a black wheel.
           (pieStrokeColor . ,page)
           (pieOuterStrokeColor . ,border)
           ;; An entity's attribute rows take their fill from `rowOdd' and
           ;; `rowEven', which mermaid derives by lightening the box colour; on
           ;; a dark page that put the page's ink on a white row.  The page's own
           ;; row surfaces keep the ink readable.
           (rowOdd . ,panel2)
           (rowEven . ,quote-bg)
           ;; A gantt's band, its grid and its today line are the light
           ;; page's greys and red on any page.
           (sectionBkgColor . ,(etaf-md--mermaid-tint page ink 0.04))
           (sectionBkgColor2 . ,(etaf-md--mermaid-tint page ink 0.04))
           (altSectionBkgColor . ,page)
           (gridColor . ,(etaf-md--mermaid-tint page ink 0.14))
           (vertLineColor . ,(etaf-md--mermaid-tint page ink 0.14))
           (todayLineColor . ,(etaf-md--hex-color
                               (etaf-md--env-color env :danger)))
           (taskBkgColor . ,panel)
           (taskBorderColor . ,border)
           (taskTextColor . ,ink)
           (taskTextOutsideColor . ,ink)
           (taskTextDarkColor . ,ink)
           (taskTextClickableColor . ,ink)
           ;; A journey's title and its actors' faces are its own colours too.
           (titleColor . ,ink)
           (faceColor . ,panel)
           ;; A quadrant's points are drawn in a fill mermaid derives by
           ;; lightening a box colour, which on a dark page hides them; the
           ;; four quadrants stay page-coloured so the grid does the dividing.
           (quadrant1Fill . ,page)
           (quadrant2Fill . ,page)
           (quadrant3Fill . ,page)
           (quadrant4Fill . ,page)
           (quadrantPointFill . ,ink)
           ;; A point's label is drawn on the page, beside the dot, not on it.
           (quadrantPointTextFill . ,ink)
           (quadrantXAxisTextFill . ,muted)
           (quadrantYAxisTextFill . ,muted)
           (quadrantInternalBorderStrokeFill . ,border)
           (quadrantExternalBorderStrokeFill . ,border)
           ;; A commit's label is what the commit says, not a footnote: mermaid
           ;; sets it at ten pixels, a size the page never uses.
           (commitLabelFontSize . ,(format "%dpx" base))
           (commitLabelColor . ,ink)
           (commitLabelBackground . ,page)
           (commitLabelBorderColor . ,border)
           (tagLabelFontSize . ,(format "%dpx" base))
           (tagLabelColor . ,ink)
           (tagLabelBackground . ,panel2)
           (tagLabelBorder . ,border)
           ;; The diagram is measured with this font as well as drawn with it:
           ;; a family the renderer's Chromium lacks makes it measure the label
           ;; narrower than the glyphs, and a CJK edge label comes out cut off.
           ;; The reader's own font comes first, so a diagram carries the same
           ;; type as the page, with the CJK face behind it and a family every
           ;; desktop has as the last resort.
           ,@(etaf-md--mermaid-family-theme env colors)
           (fontFamily . ,(etaf-md--mermaid-font-family))
           (fontSize . ,(format "%dpx" base))
           ,@(etaf-md--mermaid-categorical env page ink)
           ,@(etaf-md--mermaid-states env page ink)))
       ;; A node hugs its label.  Mermaid measures the text, adds this padding
       ;; and a minimum width of its own, and a diamond inscribes its label, so
       ;; its box grows to about twice the text's.  The wider padding inflated
       ;; every box by four pixels an axis, which left short labels in frames
       ;; with room to spare, and the spacing below keeps a wide flow chart from
       ;; being scaled down to fit the reading column.
       (flowchart . ((padding . 8) (nodeSpacing . 40) (rankSpacing . 40)
                     (wrappingWidth . 160)
                     (useMaxWidth . t) (htmlLabels . t)))
       ;; Mermaid sizes each kind of diagram on its own: a sequence diagram's
       ;; messages come out at 12px beside 14px actors, and gantt, er,
       ;; requirement and state diagrams default to 11, 12, 14 and 24.  One page
       ;; reads as one typeface, so every kind is told the page's size.  A
       ;; diagram wider than the column is still scaled to fit, and that is the
       ;; only change of size a reader sees.
       (sequence . ((diagramMarginX . 16) (diagramMarginY . 12)
                    (actorMargin . 40) (boxMargin . 10)
                    (actorFontSize . ,base) (messageFontSize . ,base)
                    (noteFontSize . ,base)))
       ;; These three carry minimum boxes of their own: a state node is 120
       ;; wide, an entity 100 by 75, a requirement 200 wide.  A short label in
       ;; one of them leaves a frame with room to spare, so the floors come down
       ;; to a size the label fills.
       ;; A commit's id is set at the angle mermaid turns it to, which a short
       ;; Latin id survives and a Chinese one does not: it is laid flat, where a
       ;; reader can read it like every other label on the page.
       (gitGraph . ((rotateCommitLabel . :json-false)))
       (gantt . ((fontSize . ,base) (sectionFontSize . ,base)))
       (er . ((fontSize . ,base) (minEntityWidth . 60) (minEntityHeight . 40)))
       (requirement . ((fontSize . ,base) (rect_min_width . 120)))
       (state . ((fontSize . ,base) (minNodeWidth . 60)))))))

;;; ---------------------------------------------------------------------------
;;; The drawing program
;;; ---------------------------------------------------------------------------

(defun etaf-md--renderer-start (script)
  "Return the drawing program's process, starting it when there is none.
SCRIPT is its path.  One process draws every picture a session shows: starting
Chromium is what a render costs, and it is started once."
  (unless (process-live-p etaf-md-typeset--renderer)
    (let ((errors (generate-new-buffer " *etaf-md-renderer-errors*")))
      (setq etaf-md-typeset--renderer-text "")
      (setq etaf-md-typeset--renderer
            (make-process
             :name "etaf-md-renderer"
             ;; The filter reads the answers as they arrive, so nothing has to
             ;; be kept: a buffer would grow with every picture drawn.
             :buffer nil
             :command (list "node" script)
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :stderr errors
             :filter #'etaf-md--renderer-filter
             :sentinel #'etaf-md--renderer-sentinel))
      (process-put etaf-md-typeset--renderer :errors errors)))
  etaf-md-typeset--renderer)

(defun etaf-md--renderer-send (request)
  "Write REQUEST to the drawing program, or return nil when it cannot start."
  (when-let* ((script (etaf-md-typeset--renderer-script))
              (process (ignore-errors (etaf-md--renderer-start script)))
              ((process-live-p process)))
    (process-send-string process (concat (json-encode request) "\n"))
    (etaf-md--renderer-reset-idle)
    process))

(defun etaf-md--renderer-reset-idle ()
  "Restart the countdown that stops an idle drawing program."
  (when (timerp etaf-md-typeset--idle-timer)
    (cancel-timer etaf-md-typeset--idle-timer))
  (setq etaf-md-typeset--idle-timer
        (run-at-time etaf-md-typeset--renderer-idle nil
                     #'etaf-md--renderer-stop)))

(defun etaf-md--renderer-stop ()
  "Stop the drawing program when it has nothing left to draw.
Chromium costs memory while it runs and a page draws its pictures once, so a
reader who stopped opening diagrams should not keep a browser around."
  (setq etaf-md-typeset--idle-timer nil)
  (when (and (process-live-p etaf-md-typeset--renderer)
             (zerop (hash-table-count etaf-md-typeset--requests)))
    (delete-process etaf-md-typeset--renderer)))

(defun etaf-md--renderer-filter (_process text)
  "Read TEXT as the renderer's answers, one JSON object per line."
  (setq etaf-md-typeset--renderer-text
        (concat etaf-md-typeset--renderer-text text))
  (let ((received etaf-md-typeset--renderer-text))
    (while (string-match "\n" received)
      (let ((line (substring received 0 (match-beginning 0))))
        (setq received (substring received (match-end 0)))
        (unless (string-blank-p line)
          (etaf-md--renderer-answer line))))
    (setq etaf-md-typeset--renderer-text received)))

(defun etaf-md--renderer-answer (line)
  "Act on one LINE of the renderer's answers."
  (when-let* ((reply (ignore-errors (json-parse-string line :object-type 'plist)))
              (id (plist-get reply :id))
              ((integerp id))
              (request (gethash id etaf-md-typeset--requests)))
    (remhash id etaf-md-typeset--requests)
    (remhash (plist-get request :key) etaf-md-typeset--running)
    (if (eq (plist-get reply :ok) t)
        (etaf-md--typeset-arrived request)
      (etaf-md--typeset-failed request (plist-get reply :error)
                                        (eq (plist-get reply :fatal) t)))
    (etaf-md--renderer-reset-idle)))

(defun etaf-md--typeset-arrived (request)
  "Call REQUEST's continuation once its picture is on disk.
A render that left no file is a failure the caller sees as the source still
painted, so nothing repaints then."
  (when (and (file-exists-p
              (etaf-md--typeset-path (plist-get request :key)))
             (plist-get request :done))
    (run-at-time 0 nil (plist-get request :done))))

(defun etaf-md--typeset-failed (request message fatal)
  "Record that REQUEST cannot be drawn, and keep its block as its source.
A diagram that does not parse is the author's text, not a picture, and draw it
again would fail the same way: FATAAL says so, and the block is remembered until
its source or the page changes.  Any other failure may pass, so the block is
left a candidate and the next repaint tries again.  Either way the renderer's
own message says what happened."
  (when fatal
    (puthash (plist-get request :key) (or message "the renderer gave no reason")
             etaf-md-typeset--failed))
  (message "Preview kept a %s block's source: %s"
           (or (plist-get request :kind) 'drawing)
           (truncate-string-to-width (or message "no reason given") 160)))

(defun etaf-md--renderer-fail-pending (reason)
  "Record REASON for every render in flight and let the blocks keep their source."
  (let ((requests nil))
    (maphash (lambda (_id request) (push request requests))
             etaf-md-typeset--requests)
    (clrhash etaf-md-typeset--requests)
    (dolist (request requests)
      (remhash (plist-get request :key) etaf-md-typeset--running)
      (etaf-md--typeset-failed request reason nil))))

(defun etaf-md--renderer-sentinel (process _event)
  "Report a drawing program that died while it had work."
  (when (memq (process-status process) '(exit signal))
    (setq etaf-md-typeset--renderer nil)
    (when (timerp etaf-md-typeset--idle-timer)
      (cancel-timer etaf-md-typeset--idle-timer)
      (setq etaf-md-typeset--idle-timer nil))
    (let* ((errors (process-get process :errors))
           (text (when (buffer-live-p errors)
                   (with-current-buffer errors
                     (let ((pipe (get-buffer-process (current-buffer))))
                       (while (and pipe (accept-process-output pipe 0))))
                     (prog1 (string-trim
                             (buffer-substring-no-properties (point-min) (point-max)))
                       (kill-buffer errors))))))
      (etaf-md--renderer-fail-pending
       (if (string-empty-p (or text ""))
           (format "the renderer exited with status %s"
                   (process-exit-status process))
         (car (split-string text "\n")))))))

(defun etaf-md--typeset-options (kind env)
  "Return the renderer's settings for KIND on ENV's page."
  (if (eq kind 'math)
      (list :ink (cdr (etaf-md--typeset-colors env))
            :pixels (etaf-md--typeset-pixels)
            :cell (cdr (etaf-md--cell-metrics)))
    ;; The configuration is JSON already.  Parsing it to a plist and encoding
    ;; it again would turn every `false' into the string "false", which the
    ;; renderer reads as true.
    (list :config (etaf-md--mermaid-config env)
          :palette (etaf-md--typeset-palette env))))

(defun etaf-md--typeset-start (key kind source env done)
  "Ask the drawing program for SOURCE's picture as KIND, and call DONE later.
The picture is drawn on the page's own palette at two device pixels per
point, which is the size `etaf-md-typeset--scale' places it at.  A
block the renderer cannot draw keeps its source and is remembered in
`etaf-md-typeset--failed'."
  (make-directory etaf-md-typeset--cache-directory t)
  (let* ((id (cl-incf etaf-md-typeset--serial))
         (request (append (list :id id :kind (symbol-name kind)
                                :source source
                                :out (etaf-md--typeset-path key))
                          (etaf-md--typeset-options kind env))))
    (puthash id (list :key key :kind kind :done done)
             etaf-md-typeset--requests)
    (puthash key id etaf-md-typeset--running)
    (if (etaf-md--renderer-send request)
        t
      (remhash id etaf-md-typeset--requests)
      (remhash key etaf-md-typeset--running)
      (etaf-md--typeset-failed
       (list :key key :kind kind) "the drawing program did not start" nil)
      nil)))

(defun etaf-md-typeset-request (session)
  "Start the renders SESSION's page needs and does not show yet.
The blocks are read from the published document, and a block whose picture is
already on disk, or already rendering, is skipped.  The programs start on a
timer, so asking costs the publish pass one comparison per picture block and
never a program launch."
  (when (etaf-md-typeset-available-p)
    (let ((env (etaf-md--env session))
          (wanted nil))
      (dolist (entry (plist-get (etaf-md--read session :document) :children))
        (let* ((block (plist-get entry :block))
               (kind (pcase (plist-get block :type)
                      ('code-block (and (equal (plist-get block :lang) "mermaid") 'mermaid))
                      ('math (and (plist-get block :display) 'math)))))
          (when-let* ((source (and kind (plist-get block :text)))
                      ((not (string-blank-p source)))
                      (key (etaf-md--typeset-key kind source env))
                      ((not (file-exists-p (etaf-md--typeset-path key))))
                      ((not (gethash key etaf-md-typeset--running)))
                      ((not (gethash key etaf-md-typeset--failed))))
            (push (list kind source key) wanted))))
      (when wanted
        (run-at-time 0 nil
                     (lambda ()
                       (dolist (entry (nreverse wanted))
                         (let ((kind (nth 0 entry))
                               (source (nth 1 entry))
                               (key (nth 2 entry)))
                           (unless (or (file-exists-p (etaf-md--typeset-path key))
                                       (gethash key etaf-md-typeset--running)
                                       (gethash key etaf-md-typeset--failed))
                             (etaf-md--typeset-start
                              key kind source env
                              (lambda () (etaf-md--typeset-changed session))))))))))))

(defun etaf-md--typeset-changed (session)
  "Repaint SESSION once, however many pictures arrive together.
Pictures land one after another as the renderer gets to them, and a page that
repainted on each arrival would reflow its reader's place a dozen times.  One
paint per burst is what a reader sees, so the first arrival schedules the paint
and the rest join it."
  (unless (plist-get session :typeset-pending)
    (plist-put session :typeset-pending t)
    (run-at-time 0.15 nil
                 (lambda ()
                   (plist-put session :typeset-pending nil)
                   (etaf-md--typeset-repaint session)))))

(defun etaf-md--typeset-repaint (session)
  "Publish SESSION's document again so the page paints its new pictures.
The republish reads the same source the page follows, so a picture that lands
while the file is not being visited publishes the file rather than nothing."
  (etaf-md--republish session))

(defun etaf-md--render-code-block (block env)
  "Return BLOCK drawn as its picture, or nil to keep its source.
Only a `mermaid' fence has a program behind it; every other language keeps the
renderer's own painting."
  (when-let* ((path (and (equal (plist-get block :lang) "mermaid")
                         (plist-get block :picture))))
    (etaf-md--typeset-figure 'mermaid path env)))

(defun etaf-md--render-math (block env)
  "Return display formula BLOCK typeset, or nil to keep the text rendering.
An inline formula is part of a sentence and keeps its text: a picture inside a
line would change the line's height."
  (when-let* ((path (and (plist-get block :display)
                         (plist-get block :picture))))
    (etaf-md--typeset-figure 'math path env)))

(provide 'etaf-md-typeset)
;;; etaf-md-typeset.el ends here
