;;; etaf-md-typeset.el --- Draw diagrams and formulas in the background -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Two block kinds carry a picture rather than prose: a fenced `mermaid' block
;; and a `$$' display formula.  The parser and the shared renderer keep them as
;; source, which is what a reader sees when no backend is available.
;;
;; When the native dynamic module (`native/etaf-md-typeset-native.{dylib,so}',
;; inspired by LuciusChen/pele.el) is built, both Mermaid diagrams (via
;; vendored Obsidian Pele + native CoreText/Pango label measurement) and display
;; formulas (via vendored MathJax TeX-to-SVG) render inside an embedded QuickJS
;; background thread with zero Chromium, Node.js or child processes, writing
;; standalone SVGs directly to the disk cache.
;;
;; When the native module is absent, or for a diagram family Pele does not
;; support, `scripts/mermaid-render.mjs' (mermaid-cli + KaTeX) serves as an
;; automatic fallback.
;;
;; A render is asynchronous and cached by what it depends on, so a repaint of
;; the same block costs one file check.  While live-editing a previously
;; rendered block, the last valid picture stays visible until the replacement
;; SVG lands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'json)
(require 'etaf-md-cache)
(require 'etaf-md-model)
(require 'etaf-md-views)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function etaf-md--native-submit "ext:etaf-md-typeset-native" (id kind source options timeout))
(declare-function etaf-md--native-poll "ext:etaf-md-typeset-native" ())
(declare-function etaf-md--native-cancel "ext:etaf-md-typeset-native" (id))
(declare-function etaf-md--native-channel "ext:etaf-md-typeset-native" (process))
(declare-function etaf-md--native-shutdown "ext:etaf-md-typeset-native" ())
(declare-function etaf-md--native-info "ext:etaf-md-typeset-native" ())

(defgroup etaf-md-typeset nil
  "Diagrams and display formulas drawn asynchronously."
  :group 'etaf-md)

(defcustom etaf-md-typeset t
  "Whether the preview draws a diagram and a display formula as pictures.
When nil, or when neither the native QuickJS module nor mermaid-cli is
available, a mermaid block and a display formula keep their source and the
plain-text rendering the shared renderer paints.  A page never waits for a
render either way: a picture that is not cached yet appears on the repaint
that follows its completion."
  :type 'boolean)

(defconst etaf-md-typeset--cache-directory
  (expand-file-name "etaf-md/typeset/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Directory holding one SVG or PNG per rendered block.")

(defconst etaf-md-typeset--scale 2
  "Pixels per point a picture is drawn at, so it stays sharp when it is placed.")

(defconst etaf-md-typeset--formula-scale 1.0
  "A display formula is set at the page's body size.
A formula is part of the text around it, so it takes the reader's own body
size; the typesetter adds the vertical air a fraction, sum or integral needs.")

(defun etaf-md--typeset-pixels ()
  "Return the pixel size to typeset a formula at.
The page's body size comes from the frame's own default font, so a reader who
changes their font size gets a formula that still matches the text."
  (max 12 (round (* (etaf-md--base-pixels)
                    etaf-md-typeset--formula-scale))))

(defvar etaf-md-typeset--running (make-hash-table :test #'equal)
  "Render in flight by block key, so one block never renders twice.")

(defvar etaf-md-typeset--prefer-native t
  "When non-nil, prefer the embedded QuickJS native module when installed.")

(defconst etaf-md-typeset--native-version "1"
  "Native dynamic module ABI/content version expected by this Elisp layer.")

(defvar etaf-md-typeset--native-failed nil
  "Cons of (PATH . MTIME) when loading that native binary failed.")

(defvar etaf-md-typeset--native-loaded nil
  "Path of the loaded native typesetting module, or nil.")

(defvar etaf-md-typeset--native-hinted nil
  "Non-nil after hinting once per session about prebuilt native rendering.")

(defvar etaf-md-typeset--native-channel nil
  "Emacs pipe process woken by the native worker thread on job completion.")

(defvar etaf-md-typeset--native-requests (make-hash-table :test #'eql)
  "Native renders in flight or queued, keyed by request id.")

(defvar etaf-md-typeset--native-waiting nil
  "FIFO list of native jobs waiting for a free worker slot.")

(defvar etaf-md-typeset--native-in-flight 0
  "Number of jobs currently submitted to the native worker thread.")

(defconst etaf-md-typeset--native-max-in-flight 32
  "Maximum concurrent jobs pushed into the native worker queue at once.")

(defconst etaf-md-typeset--native-timeout 10000
  "Per-job timeout in milliseconds for the embedded QuickJS worker.")

(defvar etaf-md-typeset--native-poll-timer nil
  "Safety drain timer active only while native jobs are pending.")

(defvar etaf-md-typeset--mmdc-missing nil
  "Non-nil once the mermaid-cli fallback was looked for and not found.")

(defconst etaf-md-typeset--renderer-idle 45
  "Seconds the fallback drawing program may idle before it is stopped.
Chromium costs memory while it runs and a page draws its pictures once, so an
editor that stopped reading diagrams should not keep a browser around.")

(defvar etaf-md-typeset--renderer nil
  "The fallback drawing program's process, or nil before the first picture.")

(defvar etaf-md-typeset--renderer-text ""
  "Answers received from the fallback renderer that do not make a whole line yet.")

(defvar etaf-md-typeset--requests (make-hash-table :test #'eql)
  "Fallback renders in flight by request id.
Each entry is a plist of `:key', `:kind' and `:done'.")

(defvar etaf-md-typeset--serial 0
  "Number of the last request handed to either backend.")

(defvar etaf-md-typeset--idle-timer nil
  "Timer that stops the fallback renderer when it has nothing left to draw.")

(defvar etaf-md-typeset--failed (make-hash-table :test #'equal)
  "Renderer's message by block key of a block that cannot be drawn.
A key holds the source and every setting the picture depends on, so a block
stays unrendered until its source or the page changes, and one bad diagram is
not retried on every keystroke that republishes the page.")

;;; ---------------------------------------------------------------------------
;;; Backend discovery
;;; ---------------------------------------------------------------------------

(defun etaf-md-typeset--package-root ()
  "Return the root directory of `etaf-md', or nil when running only from .eln."
  (when-let* ((entry (locate-library "etaf-md"))
              ((not (string-suffix-p ".eln" entry))))
    (file-name-directory entry)))

(defun etaf-md-typeset--native-cache-path ()
  "Return the unified user-cache path for the prebuilt native typeset module."
  (when (and module-file-suffix (stringp module-file-suffix))
    (let* ((cache-root
            (or (and (boundp 'etaf-install-native-directory)
                     etaf-install-native-directory)
                (expand-file-name
                 "emacs-taf/native"
                 (or (let ((xdg (getenv "XDG_CACHE_HOME")))
                       (and xdg (not (string-empty-p xdg)) xdg))
                     (expand-file-name "~/.cache")))))
           (name (concat "etaf-md-typeset-native" module-file-suffix)))
      (expand-file-name
       name
       (expand-file-name (concat "etaf-md/" etaf-md-typeset--native-version)
                         cache-root)))))

(defun etaf-md-typeset--native-module-path ()
  "Return the native typesetting module path if present in checkout or cache."
  (when (and module-file-suffix (stringp module-file-suffix))
    (let* ((root (etaf-md-typeset--package-root))
           (name (concat "etaf-md-typeset-native" module-file-suffix))
           (candidates
            (delq nil
                  (list (and root (expand-file-name name (expand-file-name "native" root)))
                        (and root (expand-file-name name root))
                        (etaf-md-typeset--native-cache-path)))))
      (cl-find-if #'file-exists-p candidates))))

(defun etaf-md-typeset--ensure-native ()
  "Ensure the native QuickJS module is loaded and its wakeup pipe is live.
Return non-nil when the native module is ready to accept jobs."
  (when (and etaf-md-typeset--prefer-native module-file-suffix)
    (unless (featurep 'etaf-md-typeset-native)
      (when-let* ((path (etaf-md-typeset--native-module-path))
                  (mtime (file-attribute-modification-time (file-attributes path))))
        (unless (and (consp etaf-md-typeset--native-failed)
                     (equal (car etaf-md-typeset--native-failed) path)
                     (equal (cdr etaf-md-typeset--native-failed) mtime))
          (condition-case err
              (progn
                (load path nil t t)
                (when (featurep 'etaf-md-typeset-native)
                  (setq etaf-md-typeset--native-loaded path
                        etaf-md-typeset--native-failed nil)))
            (error
             (setq etaf-md-typeset--native-failed (cons path mtime))
             (message "etaf-md native typeset module could not be loaded: %s"
                      (error-message-string err)))))))
    (when (featurep 'etaf-md-typeset-native)
      (unless etaf-md-typeset--native-loaded
        (setq etaf-md-typeset--native-loaded (or (etaf-md-typeset--native-module-path) t)))
      (unless (process-live-p etaf-md-typeset--native-channel)
        (setq etaf-md-typeset--native-channel
              (make-pipe-process
               :name "etaf-md-typeset-native"
               :noquery t
               :coding 'no-conversion
               :filter #'etaf-md--native-filter))
        (etaf-md--native-channel etaf-md-typeset--native-channel))
      t)))

(defun etaf-md-typeset--native-available-p ()
  "Return non-nil when the embedded QuickJS native module is ready."
  (and etaf-md-typeset
       etaf-md-typeset--prefer-native
       (etaf-md-typeset--ensure-native)))

(defun etaf-md-typeset--native-info ()
  "Return engine metadata plist when the native module is loaded, else nil."
  (when (and (etaf-md-typeset--native-available-p)
             (fboundp 'etaf-md--native-info))
    (ignore-errors (etaf-md--native-info))))

(defun etaf-md-typeset--renderer-script ()
  "Return the fallback drawing program's path, or nil when this checkout lacks it."
  (when-let* ((root (etaf-md-typeset--package-root))
              (script (expand-file-name "scripts/mermaid-render.mjs" root))
              ((file-exists-p script)))
    script))

(defun etaf-md-typeset--mmdc-available-p ()
  "Return non-nil when the Node + mermaid-cli fallback renderer is installed."
  (and etaf-md-typeset
       (not etaf-md-typeset--mmdc-missing)
       (or (and (executable-find "mmdc")
                (executable-find "node")
                (etaf-md-typeset--renderer-script))
           (progn (setq etaf-md-typeset--mmdc-missing t) nil))))

(defun etaf-md-typeset-available-p ()
  "Return non-nil when this system can draw diagrams and formulas.
Prefers the embedded QuickJS native module (`native/etaf-md-typeset-native')
and falls back to `scripts/mermaid-render.mjs' when `mmdc' and `node' exist."
  (and etaf-md-typeset
       (or (etaf-md-typeset--native-available-p)
           (etaf-md-typeset--mmdc-available-p))))

;;; ---------------------------------------------------------------------------
;;; Colors, keys and cache lookup
;;; ---------------------------------------------------------------------------

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
                         (etaf-md--env-color env :bg)))
         (dark (> (etaf-ui-color-contrast background "#ffffff")
                  (etaf-ui-color-contrast background "#000000"))))
    (cons (if dark 'dark 'light)
          (etaf-md--hex-color (etaf-md--env-color env :ink)))))

(defconst etaf-md-typeset--picture-version 7
  "Version of the drawing a cache key stands for.
Raised when the renderer's own output changes so cached pictures are redrawn.")

(defun etaf-md--typeset-page (env)
  "Return ENV's page constants for a picture key: (COLORS . CONFIG-HASH).
Built once per appearance signature and reused across blocks of that page."
  (let ((signature (list (plist-get env :theme)
                         (plist-get env :background)
                         (plist-get env :ink)
                         (etaf-md--base-pixels)
                         (if (etaf-md-typeset--native-available-p) 'native 'mmdc))))
    (let ((cached (plist-get env :typeset-page)))
      (if (and cached (equal (car cached) signature))
          (cdr cached)
        (let* ((config-str (if (etaf-md-typeset--native-available-p)
                               (etaf-md--native-mermaid-options-json env)
                             (etaf-md--mermaid-config env)))
               (page (cons (etaf-md--typeset-colors env)
                           (secure-hash 'sha1 config-str))))
          (plist-put env :typeset-page (cons signature page))
          page)))))

(defun etaf-md--typeset-key (kind source env)
  "Return the cache key of KIND drawn from SOURCE for ENV's surface.
The key holds what the picture depends on, so a theme switch or backend change
draws a fresh picture instead of reusing stale output."
  (let* ((page (etaf-md--typeset-page env))
         (colors (car page))
         (backend (if (etaf-md-typeset--native-available-p) "native" "mmdc")))
    (secure-hash 'sha1
                 (format "%s\n%s\n%d\n%s\n%s\n%s\n%s"
                         backend kind etaf-md-typeset--picture-version source
                         (car colors)
                         (cdr colors)
                         (if (eq kind 'math)
                             (format "%d/%d/%s"
                                     (etaf-md--typeset-pixels)
                                     (cdr (etaf-md--cell-metrics))
                                     (etaf-md--mermaid-font-family))
                           (cdr page))))))

(defun etaf-md--typeset-path (key)
  "Return the PNG cache path of KEY."
  (expand-file-name (concat key ".png") etaf-md-typeset--cache-directory))

(defun etaf-md--typeset-svg-path (key)
  "Return the SVG cache path of KEY."
  (expand-file-name (concat key ".svg") etaf-md-typeset--cache-directory))

(defun etaf-md--typeset-picture (key)
  "Return the picture drawn for KEY, or nil when it is not drawn yet.
Prefers a vector SVG (produced directly by the native QuickJS engine or beside
a fallback PNG) and falls back to PNG when only a raster exists."
  (let ((vector (etaf-md--typeset-svg-path key))
        (raster (etaf-md--typeset-path key)))
    (cond ((file-exists-p vector) vector)
          ((file-exists-p raster) raster))))

(defun etaf-md--typeset-block-kind (block)
  "Return `mermaid', `math' or nil for AST BLOCK."
  (pcase (plist-get block :type)
    ('code-block (and (equal (plist-get block :lang) "mermaid") 'mermaid))
    ('math (and (plist-get block :display) 'math))))

(defun etaf-md-typeset-attach (block env)
  "Return BLOCK carrying the picture already rendered for it in ENV.
Descends into container `:children' so diagrams and formulas inside cards,
tabs or columns also attach cached pictures.  When `etaf-md-typeset' is nil,
strips any `:picture' so blocks show their source cleanly.  Reading the cache
never starts a render."
  (cond
   ((eq (plist-get block :type) 'container)
    (let* ((children (plist-get block :children))
           (updated (mapcar (lambda (child) (etaf-md-typeset-attach child env))
                            children)))
      (if (cl-every #'eq children updated)
          block
        (plist-put (copy-sequence block) :children updated))))
   (t
    (let ((kind (etaf-md--typeset-block-kind block)))
      (cond
       ((not kind) block)
       ((not etaf-md-typeset)
        (if (plist-member block :picture)
            (let ((copy (copy-sequence block)))
              (cl-remf copy :picture)
              copy)
          block))
       (t
        (if-let* ((source (plist-get block :text))
                  ((not (string-blank-p source)))
                  (path (etaf-md--typeset-picture
                         (etaf-md--typeset-key kind source env))))
            (if (equal path (plist-get block :picture))
                block
              (plist-put (copy-sequence block) :picture path))
          block)))))))

(defconst etaf-md-typeset--max-rows 120
  "Upper row safety ceiling for typeset diagrams and display formulas.
Unlike standalone photo cards (`etaf-md--media-max-rows' = 20), diagrams carry
body-size vector typography inside a vertically scrolling document: bounding
them by reading-column width instead of a 20-row height cap keeps portrait
flowcharts, state machines and ER diagrams at crisp 1:1 type size.")

(defun etaf-md--typeset-figure (kind path env)
  "Return the View of the picture at PATH for KIND in ENV.
A diagram keeps a caption that opens the lightbox (or external viewer); a
formula is its own line with no frame, because it belongs to the prose around
it."
  (let* ((width (max 24 (or (plist-get env :figure-width)
                            (plist-get env :width) 92)))
         (pixels (when-let* ((natural (ignore-errors
                                        (etaf-md--image-pixels path))))
                   (cons (/ (car natural) (float etaf-md-typeset--scale))
                         (/ (cdr natural) (float etaf-md-typeset--scale)))))
         (grid (or (etaf-md--media-grid-for-pixels
                    pixels (- width 2) etaf-md-typeset--max-rows)
                   (cons width 8)))
         ;; When a 2x fallback raster sits beside the vector and still covers
         ;; the displayed pixel width, prefer decoding the raster; native SVG
         ;; outputs have no sibling PNG and render directly as crisp vectors.
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
        (etaf-node 'column
                   (list :width 'stretch :max-width (list 'ch width)
                         :cross-align 'center)
                   (list image))
      (let ((open-file (plist-get env :open-file))
            (open-lightbox (plist-get env :open-lightbox))
            (caption (format "%s（按 RET 放大/打开）" (file-name-nondirectory path))))
        (etaf-node 'column
                   (list :width 'stretch :max-width (list 'ch width)
                         :cross-align 'center :item-gap '(lh 0)
                         :on-press (lambda ()
                                     (etaf-md--activate-media
                                      env 'image path
                                      (lambda ()
                                        (unless (and (functionp open-lightbox)
                                                     (funcall open-lightbox path "Mermaid 图表"))
                                          (when open-file
                                            (funcall open-file path))))))
                         :role 'button :tab-index 0 :pointer 'hand
                         :help-echo caption)
                   (list image
                         (etaf-md--caption-view "▲ mermaid" env)))))))

;;; ---------------------------------------------------------------------------
;;; Typography and theme mapping
;;; ---------------------------------------------------------------------------

(defconst etaf-md-mermaid-fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Families a diagram falls back to when the reader's own font lacks a glyph.")

(defconst etaf-md-mermaid-mono-fonts
  '("LXGW WenKai Mono" "Menlo" "Monaco" "DejaVu Sans Mono" "monospace")
  "Monospace families for code labels inside diagrams.")

(defun etaf-md--mermaid-font-family ()
  "Return the font stack a diagram is drawn and measured with.
The reader's default face comes first, so a diagram uses the type they read
the page in; the names after it cover the glyphs that face may lack."
  (let* ((family (ignore-errors (face-attribute 'default :family nil t)))
         (names (if (and (stringp family)
                         (not (string-empty-p family))
                         (not (string= family "default")))
                    (cons family etaf-md-mermaid-fonts)
                  etaf-md-mermaid-fonts)))
    (mapconcat #'identity (delete-dups names) ", ")))

(defun etaf-md--mermaid-mono-font-family ()
  "Return the monospace font stack used for code labels inside diagrams."
  (mapconcat #'identity etaf-md-mermaid-mono-fonts ", "))

(defconst etaf-md--mermaid-hues
  '(:accent :ok :warn :important :danger :muted)
  "Theme colors a diagram takes its categorical series from.")

(defconst etaf-md--mermaid-fill-contrast 3.0
  "Contrast ratio a diagram's label keeps against the fill under it.")

(defconst etaf-md--mermaid-fill-separation 1.5
  "Contrast ratio a category fill keeps against the page it is drawn on.")

(defun etaf-md--mermaid-fill (page ink hue &optional label separate)
  "Return (FILL . LABEL) for HUE mixed into PAGE, and for the label on it."
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
  "Return ENV's page colours, keyed by role, as #rrggbb."
  (let ((role (lambda (key)
                (etaf-md--hex-color (etaf-md--env-color env key)))))
    (list :ink (funcall role :ink)
          :panel (funcall role :panel)
          :panel2 (funcall role :panel2)
          :border (funcall role :border)
          :muted (funcall role :muted)
          :quote (funcall role :quote-bg)
          :accent (funcall role :accent)
          :ok (funcall role :ok)
          :warn (funcall role :warn)
          :important (funcall role :important)
          :danger (funcall role :danger)
          :page (etaf-md--hex-color
                 (or (plist-get env :background)
                     (etaf-md--env-color env :bg))))))

(defun etaf-md--pele-theme (env)
  "Return a hash table of Pele CSS custom properties derived from ENV's palette.
Every color is derived from the active page theme (`dark', `light', `sepia' or
face-derived `auto'), so diagrams harmonize with the surrounding document."
  (let* ((colors (etaf-md--page-colors env))
         (page (plist-get colors :page))
         (ink (plist-get colors :ink))
         (muted (plist-get colors :muted))
         (border (plist-get colors :border))
         (panel (plist-get colors :panel))
         (panel2 (plist-get colors :panel2))
         (accent (plist-get colors :accent))
         (ok (plist-get colors :ok))
         (warn (plist-get colors :warn))
         (important (plist-get colors :important))
         (danger (plist-get colors :danger))
         ;; Slightly elevate line & border contrast against muted panel surfaces.
         (line (etaf-md--mix-color muted ink 0.35))
         (stroke (etaf-md--mix-color border muted 0.35))
         (table (make-hash-table :test #'equal)))
    (dolist (pair
             `(("__dummy" . nil)
               ("--pele-bg" . ,page)
               ("--pele-fg" . ,ink)
               ("--pele-muted" . ,muted)
               ("--pele-line" . ,line)
               ("--pele-surface" . ,panel)
               ("--pele-surface-alt" . ,panel2)
               ("--pele-border" . ,stroke)
               ("--pele-accent" . ,accent)
               ("--pele-critical" . ,danger)
               ("--pele-error" . ,danger)
               ("--pele-fg-on-dark" . "#f3f5f8")
               ("--pele-fg-on-light" . "#1a1d23")
               ("--pele-radius" . "6px")
               ("--pele-series-1" . ,accent)
               ("--pele-series-2" . ,ok)
               ("--pele-series-3" . ,warn)
               ("--pele-series-4" . ,important)
               ("--pele-series-5" . ,danger)
               ("--pele-series-6" . ,(etaf-md--mix-color accent ok 0.5))
               ("--pele-series-7" . ,(etaf-md--mix-color warn danger 0.5))
               ("--pele-series-8" . ,(etaf-md--mix-color important danger 0.5))))
      (when (cdr pair)
        (puthash (car pair) (cdr pair) table)))
    table))

(defun etaf-md--native-mermaid-options-json (env)
  "Return the JSON options string passed to the native QuickJS Pele engine."
  (let ((base (max 10 (round (etaf-md--base-pixels)))))
    (json-serialize
     `((fontSize . ,base)
       (fontFamily . ,(etaf-md--mermaid-font-family))
       (fontFamilyMono . ,(etaf-md--mermaid-mono-font-family))
       (measureText . t)
       (transparentBackground . t)
       (scale . ,etaf-md-typeset--scale)
       (theme . ,(etaf-md--pele-theme env)))
     :false-object :false)))

(defun etaf-md--native-math-options-json (env)
  "Return the JSON options string passed to the native QuickJS MathJax engine."
  (json-serialize
   `((ink . ,(cdr (etaf-md--typeset-colors env)))
     (pixels . ,(etaf-md--typeset-pixels))
     (cell . ,(cdr (etaf-md--cell-metrics)))
     (scale . ,etaf-md-typeset--scale)
     (fontFamily . ,(etaf-md--mermaid-font-family)))
   :false-object :false))

(defun etaf-md--mermaid-tint (page ink weight)
  "Return PAGE moved toward INK by WEIGHT."
  (etaf-md--mix-color page ink weight))

(defun etaf-md--mermaid-states (env page ink)
  "Return the surfaces a gantt paints a task's state with."
  (let ((surface (lambda (key prefix)
                   (let* ((hue (etaf-md--hex-color
                                (etaf-md--env-color env key)))
                          (fill (car (etaf-md--mermaid-fill
                                      page ink hue ink 'no))))
                     (list (cons (intern (concat prefix "BkgColor")) fill)
                           (cons (intern (concat prefix "BorderColor")) hue))))))
    (append (funcall surface :ok "doneTask")
            (funcall surface :accent "activeTask")
            (funcall surface :danger "crit"))))

(defun etaf-md--mermaid-family-theme (env colors)
  "Return the theme variables that later diagram families read."
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
  "Return ENV's category colours, keyed by role."
  (mapcar (lambda (key)
            (let* ((hue (etaf-md--hex-color
                         (etaf-md--env-color env key)))
                   (fill (etaf-md--mermaid-fill page ink hue)))
              (list :hue hue :fill (car fill) :label (cdr fill))))
          etaf-md--mermaid-hues))

(defun etaf-md--mermaid-plot-colours (env page ink)
  "Return a chart's series colours as a comma-separated list."
  (let ((series (etaf-md--mermaid-series env page ink)))
    (mapconcat #'identity
               (cl-loop for index from 0 below 6
                        for entry = (nth (mod index (length series)) series)
                        collect (plist-get entry (if (cl-evenp index) :fill :hue)))
               ",")))

(defun etaf-md--mermaid-categorical (env page ink)
  "Return the theme variables that colour ENV's diagram categories."
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
                           (cons (intern (format "fillType%d" i)) fill)
                           (cons (intern (format "actor%d" i)) hue))))))

(defun etaf-md--typeset-palette (env)
  "Return the page's colours as the fallback drawing program names them."
  (let ((colors (etaf-md--page-colors env)))
    (list :page (plist-get colors :page)
          :ink (plist-get colors :ink)
          :line (plist-get colors :muted)
          :panel (plist-get colors :panel)
          :danger (plist-get colors :danger))))

(defun etaf-md--mermaid-config (env)
  "Return the mermaid-cli configuration JSON drawn for ENV's page."
  (let* ((colors (etaf-md--page-colors env))
         (ink (plist-get colors :ink))
         (panel (plist-get colors :panel))
         (panel2 (plist-get colors :panel2))
         (border (plist-get colors :border))
         (muted (plist-get colors :muted))
         (quote-bg (plist-get colors :quote))
         (page (plist-get colors :page))
         (base (max 8 (round (etaf-md--base-pixels)))))
    (json-encode
     `((look . "classic")
       (theme . "base")
       (htmlLabels . :json-false)
       (themeVariables
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
           (clusterBkg . ,(etaf-md--mermaid-tint page ink 0.06))
           (clusterBorder . ,border)
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
           (pieStrokeColor . ,page)
           (pieOuterStrokeColor . ,border)
           (rowOdd . ,panel2)
           (rowEven . ,quote-bg)
           (sectionBkgColor . ,(etaf-md--mermaid-tint page ink 0.04))
           (sectionBkgColor2 . ,(etaf-md--mermaid-tint page ink 0.04))
           (altSectionBkgColor . ,page)
           (gridColor . ,(etaf-md--mermaid-tint page ink 0.14))
           (vertLineColor . ,(etaf-md--mermaid-tint page ink 0.14))
           (todayLineColor . ,(plist-get colors :danger))
           (taskBkgColor . ,panel)
           (taskBorderColor . ,border)
           (taskTextColor . ,ink)
           (taskTextOutsideColor . ,ink)
           (taskTextDarkColor . ,ink)
           (taskTextClickableColor . ,ink)
           (titleColor . ,ink)
           (faceColor . ,panel)
           (quadrant1Fill . ,page)
           (quadrant2Fill . ,page)
           (quadrant3Fill . ,page)
           (quadrant4Fill . ,page)
           (quadrantPointFill . ,ink)
           (quadrantPointTextFill . ,ink)
           (quadrantXAxisTextFill . ,muted)
           (quadrantYAxisTextFill . ,muted)
           (quadrantInternalBorderStrokeFill . ,border)
           (quadrantExternalBorderStrokeFill . ,border)
           (commitLabelFontSize . ,(format "%dpx" base))
           (commitLabelColor . ,ink)
           (commitLabelBackground . ,page)
           (commitLabelBorderColor . ,border)
           (tagLabelFontSize . ,(format "%dpx" base))
           (tagLabelColor . ,ink)
           (tagLabelBackground . ,panel2)
           (tagLabelBorderColor . ,border)
           ,@(etaf-md--mermaid-family-theme env colors)
           (fontFamily . ,(etaf-md--mermaid-font-family))
           (fontSize . ,(format "%dpx" base))
           ,@(etaf-md--mermaid-categorical env page ink)
           ,@(etaf-md--mermaid-states env page ink)))
       (flowchart . ((padding . 8) (nodeSpacing . 40) (rankSpacing . 40)
                     (wrappingWidth . 160)
                     (useMaxWidth . t) (htmlLabels . t)))
       (sequence . ((diagramMarginX . 16) (diagramMarginY . 12)
                    (actorMargin . 40) (boxMargin . 10)
                    (actorFontSize . ,base) (messageFontSize . ,base)
                    (noteFontSize . ,base)))
       (gitGraph . ((rotateCommitLabel . :json-false)))
       (gantt . ((fontSize . ,base) (sectionFontSize . ,base)))
       (er . ((fontSize . ,base) (minEntityWidth . 60) (minEntityHeight . 40)))
       (requirement . ((fontSize . ,base) (rect_min_width . 120)))
       (state . ((fontSize . ,base) (minNodeWidth . 60)))))))

;;; ---------------------------------------------------------------------------
;;; Primary backend: embedded QuickJS native module (inspired by pele.el)
;;; ---------------------------------------------------------------------------

(defun etaf-md--typeset-write-svg (key svg)
  "Write UTF-8 SVG text atomically to KEY's cache path and return that path."
  (make-directory etaf-md-typeset--cache-directory t)
  (let* ((target (etaf-md--typeset-svg-path key))
         (tmp (make-temp-file
               (expand-file-name ".typeset-" etaf-md-typeset--cache-directory)
               nil ".svg"))
         (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert svg))
          (rename-file tmp target t)
          target)
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun etaf-md--native-stop-poll-timer ()
  "Cancel the native safety poll timer when no jobs remain."
  (when (timerp etaf-md-typeset--native-poll-timer)
    (cancel-timer etaf-md-typeset--native-poll-timer)
    (setq etaf-md-typeset--native-poll-timer nil)))

(defun etaf-md--native-dispatch ()
  "Submit queued native jobs up to `etaf-md-typeset--native-max-in-flight'."
  (while (and etaf-md-typeset--native-waiting
              (< etaf-md-typeset--native-in-flight
                 etaf-md-typeset--native-max-in-flight))
    (let* ((entry (pop etaf-md-typeset--native-waiting))
           (id (nth 0 entry))
           (kind-str (nth 1 entry))
           (source (nth 2 entry))
           (options-json (nth 3 entry))
           (request (gethash id etaf-md-typeset--native-requests)))
      (when request
        (condition-case err
            (progn
              (etaf-md--native-submit
               id kind-str source options-json etaf-md-typeset--native-timeout)
              (cl-incf etaf-md-typeset--native-in-flight))
          (error
           (remhash id etaf-md-typeset--native-requests)
           (remhash (plist-get request :key) etaf-md-typeset--running)
           (etaf-md--typeset-failed
            request (error-message-string err) nil)))))))

(defun etaf-md--native-unsupported-p (err-plist)
  "Return non-nil when ERR-PLIST indicates an unsupported diagram type."
  (let ((code (downcase (or (plist-get err-plist :code) "")))
        (msg (downcase (or (plist-get err-plist :message) ""))))
    (or (string-match-p "unsupported\\|unknown" code)
        (string-match-p "unsupported\\|unknown diagram\\|not supported" msg))))

(defun etaf-md--native-handle-result (id json-text)
  "Process one native worker completion for ID with JSON-TEXT."
  (when-let* ((request (gethash id etaf-md-typeset--native-requests)))
    (remhash id etaf-md-typeset--native-requests)
    (when (> etaf-md-typeset--native-in-flight 0)
      (cl-decf etaf-md-typeset--native-in-flight))
    (let* ((key (plist-get request :key))
           (parsed (ignore-errors
                     (json-parse-string json-text
                                        :object-type 'plist
                                        :array-type 'list
                                        :false-object nil
                                        :null-object nil))))
      (cond
       ((and (plist-get parsed :ok) (stringp (plist-get parsed :svg)))
        (remhash key etaf-md-typeset--running)
        (etaf-md--typeset-write-svg key (plist-get parsed :svg))
        (etaf-md--typeset-arrived request))
       (t
        (let* ((err (plist-get parsed :error))
               (code (or (plist-get err :code) "render"))
               (msg (or (plist-get err :message) "native renderer failed"))
               (transient (member code '("timeout" "cancelled" "memory" "engine"))))
          ;; If Pele does not support this diagram dialect and mermaid-cli is
          ;; installed, transparently retry the same block through mmdc.
          (if (and (eq (plist-get request :kind) 'mermaid)
                   (etaf-md--native-unsupported-p err)
                   (etaf-md-typeset--mmdc-available-p))
              (progn
                (remhash key etaf-md-typeset--running)
                (etaf-md--typeset-start-mmdc
                 key
                 (plist-get request :kind)
                 (plist-get request :source)
                 (plist-get request :env)
                 (plist-get request :done)))
            (remhash key etaf-md-typeset--running)
            (etaf-md--typeset-failed request msg (not transient)))))))))

(defun etaf-md--native-drain ()
  "Drain completed results from the native QuickJS worker without blocking."
  (etaf-md--native-dispatch)
  (when (featurep 'etaf-md-typeset-native)
    (let ((limit 64)
          entry)
      (while (and (> limit 0) (setq entry (etaf-md--native-poll)))
        (cl-decf limit)
        (etaf-md--native-handle-result (car entry) (cadr entry)))))
  (etaf-md--native-dispatch)
  (when (and (zerop (hash-table-count etaf-md-typeset--native-requests))
             (null etaf-md-typeset--native-waiting))
    (etaf-md--native-stop-poll-timer)))

(defun etaf-md--native-filter (_process _text)
  "Pipe wakeup filter invoked by Emacs whenever the native worker completes a job."
  (etaf-md--native-drain))

(defun etaf-md--native-shutdown-all ()
  "Cleanly shut down the native QuickJS worker before Emacs exits."
  (etaf-md--native-stop-poll-timer)
  (setq etaf-md-typeset--native-waiting nil
        etaf-md-typeset--native-in-flight 0)
  (clrhash etaf-md-typeset--native-requests)
  (when (and (featurep 'etaf-md-typeset-native)
             (fboundp 'etaf-md--native-shutdown))
    (ignore-errors (etaf-md--native-shutdown)))
  (when (process-live-p etaf-md-typeset--native-channel)
    (ignore-errors (delete-process etaf-md-typeset--native-channel)))
  (setq etaf-md-typeset--native-channel nil))

(add-hook 'kill-emacs-hook #'etaf-md--native-shutdown-all)

(defun etaf-md--typeset-start-native (key kind source env done)
  "Queue SOURCE of KIND for KEY on the embedded QuickJS worker."
  (when (etaf-md-typeset--ensure-native)
    (let* ((id (cl-incf etaf-md-typeset--serial))
           (kind-str (symbol-name kind))
           (options-json (if (eq kind 'math)
                             (etaf-md--native-math-options-json env)
                           (etaf-md--native-mermaid-options-json env))))
      (puthash id (list :key key :kind kind :source source :env env :done done)
               etaf-md-typeset--native-requests)
      (puthash key id etaf-md-typeset--running)
      (setq etaf-md-typeset--native-waiting
            (nconc etaf-md-typeset--native-waiting
                   (list (list id kind-str source options-json))))
      (etaf-md--native-dispatch)
      (unless (timerp etaf-md-typeset--native-poll-timer)
        (setq etaf-md-typeset--native-poll-timer
              (run-at-time 0.02 0.04 #'etaf-md--native-drain)))
      t)))

;;; ---------------------------------------------------------------------------
;;; Fallback backend: scripts/mermaid-render.mjs (mermaid-cli + KaTeX)
;;; ---------------------------------------------------------------------------

(defun etaf-md--renderer-start (script)
  "Return the fallback drawing program's process, starting it when needed."
  (unless (process-live-p etaf-md-typeset--renderer)
    (let ((errors (generate-new-buffer " *etaf-md-renderer-errors*")))
      (setq etaf-md-typeset--renderer-text "")
      (setq etaf-md-typeset--renderer
            (make-process
             :name "etaf-md-renderer"
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
  "Write REQUEST to the fallback drawing program, or return nil if unavailable."
  (when-let* ((script (etaf-md-typeset--renderer-script))
              (process (ignore-errors (etaf-md--renderer-start script)))
              ((process-live-p process)))
    (process-send-string process (concat (json-encode request) "\n"))
    (etaf-md--renderer-reset-idle)
    process))

(defun etaf-md--renderer-reset-idle ()
  "Restart the countdown that stops an idle fallback drawing program."
  (when (timerp etaf-md-typeset--idle-timer)
    (cancel-timer etaf-md-typeset--idle-timer))
  (setq etaf-md-typeset--idle-timer
        (run-at-time etaf-md-typeset--renderer-idle nil
                     #'etaf-md--renderer-stop)))

(defun etaf-md--renderer-stop ()
  "Stop the fallback drawing program when it has nothing left to draw."
  (setq etaf-md-typeset--idle-timer nil)
  (when (and (process-live-p etaf-md-typeset--renderer)
             (zerop (hash-table-count etaf-md-typeset--requests)))
    (delete-process etaf-md-typeset--renderer)))

(defun etaf-md--renderer-filter (_process text)
  "Read TEXT as the fallback renderer's answers, one JSON object per line."
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
  "Act on one LINE of the fallback renderer's answers."
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
  "Call REQUEST's continuation once its picture is on disk."
  (when (and (etaf-md--typeset-picture (plist-get request :key))
             (plist-get request :done))
    (etaf-md-cache-prune-directory etaf-md-typeset--cache-directory)
    (run-at-time 0 nil (plist-get request :done))))

(defun etaf-md--typeset-failed (request message fatal)
  "Record that REQUEST cannot be drawn.
FATAL remembers syntax errors until the source or page changes; transient
failures leave the block eligible for retry."
  (when fatal
    (puthash (plist-get request :key) (or message "the renderer gave no reason")
             etaf-md-typeset--failed))
  (message "Preview kept a %s block's source: %s"
           (or (plist-get request :kind) 'drawing)
           (truncate-string-to-width (or message "no reason given") 160)))

(defun etaf-md--renderer-fail-pending (reason)
  "Record REASON for every fallback render in flight."
  (let ((requests nil))
    (maphash (lambda (_id request) (push request requests))
             etaf-md-typeset--requests)
    (clrhash etaf-md-typeset--requests)
    (dolist (request requests)
      (remhash (plist-get request :key) etaf-md-typeset--running)
      (etaf-md--typeset-failed request reason nil))))

(defun etaf-md--renderer-sentinel (process _event)
  "Report a fallback drawing program that died while it had work."
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
  "Return the fallback renderer's settings for KIND on ENV's page."
  (if (eq kind 'math)
      (list :ink (cdr (etaf-md--typeset-colors env))
            :pixels (etaf-md--typeset-pixels)
            :cell (cdr (etaf-md--cell-metrics)))
    (list :config (etaf-md--mermaid-config env)
          :palette (etaf-md--typeset-palette env))))

(defun etaf-md--typeset-start-mmdc (key kind source env done)
  "Ask the fallback Node/mmdc renderer for SOURCE's picture as KIND."
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

(defun etaf-md--typeset-start (key kind source env done)
  "Draw SOURCE as KIND under KEY on ENV's page and call DONE when ready.
Uses the embedded QuickJS native module when available, falling back to
`scripts/mermaid-render.mjs' otherwise."
  (if (etaf-md-typeset--native-available-p)
      (etaf-md--typeset-start-native key kind source env done)
    (etaf-md--typeset-start-mmdc key kind source env done)))

;;; ---------------------------------------------------------------------------
;;; Request collection & repaint batching
;;; ---------------------------------------------------------------------------

(defun etaf-md--typeset-collect-blocks (blocks env acc)
  "Collect missing typeset jobs from BLOCKS in ENV into ACC."
  (dolist (block blocks)
    (if (eq (plist-get block :type) 'container)
        (setq acc (etaf-md--typeset-collect-blocks
                   (plist-get block :children) env acc))
      (when-let* ((kind (etaf-md--typeset-block-kind block))
                  (source (plist-get block :text))
                  ((not (string-blank-p source)))
                  (key (etaf-md--typeset-key kind source env))
                  ((not (etaf-md--typeset-picture key)))
                  ((not (gethash key etaf-md-typeset--running)))
                  ((not (gethash key etaf-md-typeset--failed))))
        (push (list kind source key) acc))))
  acc)

(defun etaf-md-typeset-request (session)
  "Start the renders SESSION's page needs and does not show yet.
Reads blocks from the published document (including nested containers) and
skips any block already cached, in flight, or recorded as a syntax failure."
  (when etaf-md-typeset
    (let* ((env (etaf-md--env session))
           (blocks (mapcar (lambda (entry) (plist-get entry :block))
                           (plist-get (etaf-md--read session :document) :children)))
           (wanted (etaf-md--typeset-collect-blocks blocks env nil)))
      (when wanted
        (if (etaf-md-typeset-available-p)
            (run-at-time
             0 nil
             (lambda ()
               (dolist (entry (nreverse wanted))
                 (let ((kind (nth 0 entry))
                       (source (nth 1 entry))
                       (key (nth 2 entry)))
                   (unless (or (etaf-md--typeset-picture key)
                               (gethash key etaf-md-typeset--running)
                               (gethash key etaf-md-typeset--failed))
                     (etaf-md--typeset-start
                      key kind source env
                      (lambda () (etaf-md--typeset-changed session))))))))
          (when (and (not noninteractive)
                     (not etaf-md-typeset--native-hinted))
            (setq etaf-md-typeset--native-hinted t)
            (message "etaf-md: Mermaid/math kept as source; run M-x etaf-install-native to enable fast zero-browser SVG rendering.")))))))

(defun etaf-md--typeset-changed (session)
  "Repaint SESSION once, however many pictures arrive together."
  (unless (plist-get session :typeset-pending)
    (plist-put session :typeset-pending t)
    (run-at-time 0.05 nil
                 (lambda ()
                   (plist-put session :typeset-pending nil)
                   (etaf-md--typeset-repaint session)))))

(defun etaf-md--typeset-repaint (session)
  "Attach newly rendered pictures on SESSION's blocks and repaint them in place."
  (if (fboundp 'etaf-md--refresh-block-assets)
      (etaf-md--refresh-block-assets session)
    (etaf-md--republish session)))

(defun etaf-md--render-code-block (block env)
  "Return BLOCK drawn as its picture, or nil to keep its source."
  (when-let* ((path (and (equal (plist-get block :lang) "mermaid")
                         (plist-get block :picture))))
    (etaf-md--typeset-figure 'mermaid path env)))

(defun etaf-md--render-math (block env)
  "Return display formula BLOCK typeset, or nil to keep the text rendering."
  (when-let* ((path (and (plist-get block :display)
                         (plist-get block :picture))))
    (etaf-md--typeset-figure 'math path env)))

(provide 'etaf-md-typeset)
;;; etaf-md-typeset.el ends here
