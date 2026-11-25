;;; etaf-org-typeset.el --- Persistent SVG/KaTeX & diagram rendering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Draws display formulas (`$$...$$', `\[...\]', LaTeX environments) via KaTeX
;; and diagram source blocks (`mermaid', plus pluggable `etaf-org-src-renderers'
;; such as `svg', `dot'/`graphviz', `plantuml') asynchronously into bounded LRU
;; disk caches.
;;
;; Mermaid and KaTeX share one long-lived Chromium worker (`scripts/mermaid-render.mjs')
;; that produces sharp SVG vectors (plus raster fallback) tinted to the active
;; page palette, with per-page cached configuration.  Rendering never starts a
;; subprocess; finished pictures repaint only their owning block.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-org-cache)
(require 'etaf-org-theme)
(require 'etaf-org-env)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function etaf-org--env "etaf-org-model" (session))
(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--refresh-block-assets "etaf-org-model" (session))
(declare-function etaf-org--walk-document-blocks "etaf-org-model" (document fn))
(declare-function etaf-org--activate-media "etaf-org-model" (session kind path))

(defgroup etaf-org-typeset nil
  "Formulas and diagrams drawn by external programs."
  :group 'etaf-org)

(defcustom etaf-org-typeset t
  "Whether display formulas and diagram source blocks are drawn as pictures.
When nil, or when required external programs are absent, blocks keep their
readable source text.  Rendering never blocks: newly finished pictures repaint
only their owning block."
  :type 'boolean
  :group 'etaf-org)

(defvar etaf-org-src-renderers nil
  "Alist mapping lowercase source block language strings to custom renderer fns.
Each entry is `(LANG . FN)' where FN receives `(BLOCK ENV)' and returns an ETAF
View, or nil to fall back to the built-in code/diagram renderer.")

(defconst etaf-org-typeset--cache-directory
  (expand-file-name "typeset/" etaf-org-cache--root-directory)
  "Directory holding cached PNG/SVG files for formulas and Mermaid diagrams.")

(defconst etaf-org-typeset--diagram-directory
  (expand-file-name "diagrams/" etaf-org-cache--root-directory)
  "Directory holding cached SVG files for Graphviz/PlantUML/inline SVG blocks.")

(defconst etaf-org-typeset--scale 2
  "Device pixels per point used by the Chromium renderer.")

(defconst etaf-org-typeset--picture-version 7
  "Cache-busting pipeline version.")

(defconst etaf-org-typeset--renderer-idle 45
  "Idle timeout in seconds before stopping the persistent Chromium worker.")

(defvar etaf-org-typeset--running (make-hash-table :test #'equal)
  "Render jobs currently in flight, keyed by cache key.")

(defvar etaf-org-typeset--failed (make-hash-table :test #'equal)
  "Fatal parse/render errors keyed by cache key so bad blocks are not retried.")

(defvar etaf-org-typeset--missing nil
  "Cached flag set non-nil when `mmdc'/`node'/worker script is unavailable.")

(defvar etaf-org-typeset--renderer nil
  "Persistent Node/Chromium worker process, or nil.")

(defvar etaf-org-typeset--renderer-text ""
  "Partial stdout buffer from the worker process.")

(defvar etaf-org-typeset--requests (make-hash-table)
  "In-flight worker requests keyed by integer request id.")

(defvar etaf-org-typeset--serial 0
  "Monotonic request counter for the worker process.")

(defvar etaf-org-typeset--idle-timer nil
  "Idle shutdown timer for the worker process.")

(defun etaf-org-typeset--renderer-script ()
  "Return path to `scripts/mermaid-render.mjs', or nil if absent."
  (when-let* ((entry (locate-library "etaf-org"))
              ((not (string-suffix-p ".eln" entry)))
              (script (expand-file-name "scripts/mermaid-render.mjs"
                                        (file-name-directory entry)))
              ((file-exists-p script)))
    script))

(defun etaf-org-typeset-available-p ()
  "Return non-nil when this system can draw Mermaid diagrams and KaTeX math."
  (and etaf-org-typeset
       (not etaf-org-typeset--missing)
       (or (and (executable-find "mmdc")
                (executable-find "node")
                (etaf-org-typeset--renderer-script))
           (progn (setq etaf-org-typeset--missing t) nil))))

;;; ---------------------------------------------------------------------------
;;; Header-only image dimension reader (fast, zero rasterization on SVG/PNG)
;;; ---------------------------------------------------------------------------

(defun etaf-org-typeset--svg-pixels (path)
  "Read `(WIDTH . HEIGHT)' from SVG file header at PATH, or nil."
  (when (and (stringp path) (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path nil 0 4096)
      (let ((head (buffer-string)))
        (cond
         ((string-match "viewBox=[\"'][ \t]*[-0-9.]+[ \t,]+[-0-9.]+[ \t,]+\\([0-9.]+\\)[ \t,]+\\([0-9.]+\\)" head)
          (let ((w (string-to-number (match-string 1 head)))
                (h (string-to-number (match-string 2 head))))
            (when (and (> w 0) (> h 0)) (cons w h))))
         ((and (string-match "\\bwidth=[\"']\\([0-9.]+\\)" head)
               (let ((w (string-to-number (match-string 1 head))))
                 (when (string-match "\\bheight=[\"']\\([0-9.]+\\)" head)
                   (let ((h (string-to-number (match-string 1 head))))
                     (when (and (> w 0) (> h 0)) (cons w h))))))))))))

(defun etaf-org-typeset--png-pixels (path)
  "Read `(WIDTH . HEIGHT)' from PNG IHDR header at PATH, or nil."
  (when (and (stringp path) (file-readable-p path))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path nil 0 24)
      (when (and (>= (buffer-size) 24)
                 (equal (buffer-substring-no-properties 1 9)
                        "\x89PNG\r\n\x1a\n"))
        (let ((w (+ (ash (char-after 17) 24) (ash (char-after 18) 16)
                    (ash (char-after 19) 8) (char-after 20)))
              (h (+ (ash (char-after 21) 24) (ash (char-after 22) 16)
                    (ash (char-after 23) 8) (char-after 24))))
          (when (and (> w 0) (> h 0)) (cons w h)))))))

(defun etaf-org-typeset--image-pixels (path)
  "Return `(WIDTH . HEIGHT)' in pixels for PATH via fast header inspection."
  (let ((ext (downcase (or (file-name-extension (or path "")) ""))))
    (or (pcase ext
          ("svg" (etaf-org-typeset--svg-pixels path))
          ("png" (etaf-org-typeset--png-pixels path))
          (_ nil))
        (when (and path (file-readable-p path))
          (ignore-errors (image-size (create-image path) t))))))

(defun etaf-org-typeset--grid-for-pixels (pixels max-columns &optional max-rows)
  "Return `(COLUMNS . ROWS)' fitting PIXELS inside MAX-COLUMNS and MAX-ROWS."
  (if (or (not (consp pixels))
          (not (numberp (car pixels)))
          (not (numberp (cdr pixels))))
      (cons (min max-columns 48) (min (or max-rows 14) 14))
    (let* ((cell (etaf-org--cell-metrics))
           (cw (float (car cell)))
           (ch (float (cdr cell)))
           (nw (max 1.0 (float (car pixels))))
           (nh (max 1.0 (float (cdr pixels))))
           (fitted-w (min nw (* (max 4 max-columns) cw)))
           (fitted-h (* nh (/ fitted-w nw)))
           (cap-h (if max-rows (min fitted-h (* max-rows ch)) fitted-h))
           (scale (/ cap-h nh))
           (rows (max 1 (round (/ (* nh scale) ch))))
           (cols (max 1 (min max-columns (round (/ (* nw scale) cw))))))
      (cons cols rows))))

;;; ---------------------------------------------------------------------------
;;; Mermaid theme palette configuration (full 20-diagram palette injection)
;;; ---------------------------------------------------------------------------

(defconst etaf-org-mermaid-fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Fallback font stack for Mermaid labels including CJK glyphs.")

(defconst etaf-org--mermaid-hues
  '(:accent :ok :warn :important :danger :muted)
  "Categorical hues taken from the page's own semantic callout tokens.")

(defun etaf-org-typeset--mermaid-font-family ()
  "Return the font stack for Mermaid drawings."
  (let* ((family (ignore-errors (face-attribute 'default :family nil t)))
         (names (if (and (stringp family)
                         (not (string-empty-p family))
                         (not (string= family "default")))
                    (cons family etaf-org-mermaid-fonts)
                  etaf-org-mermaid-fonts)))
    (mapconcat #'identity (delete-dups names) ", ")))

(defun etaf-org-typeset--page-colors (env)
  "Return ENV's hex page colors keyed by role."
  (let ((role (lambda (k) (etaf-org--hex-color (etaf-org--env-color env k)))))
    (list :ink (funcall role :ink)
          :panel (funcall role :panel)
          :panel2 (funcall role :panel2)
          :border (funcall role :border)
          :muted (funcall role :muted)
          :quote (funcall role :quote-bg)
          :danger (funcall role :danger)
          :page (etaf-org--hex-color
                 (or (plist-get env :background)
                     (etaf-org--env-color env :bg))))))

(defun etaf-org-typeset--colors (env)
  "Return `(PALETTE-SYM . INK-HEX)' for ENV's page."
  (let* ((colors (etaf-org-typeset--page-colors env))
         (bg (plist-get colors :page))
         (dark (> (or (etaf-org--contrast-ratio bg "#ffffff") 0)
                  (or (etaf-org--contrast-ratio bg "#000000") 0))))
    (cons (if dark 'dark 'light) (plist-get colors :ink))))

(defun etaf-org-typeset--mermaid-fill (page ink hue &optional label separate)
  "Compute accessible `(FILL . LABEL)' mixing HUE into PAGE."
  (let ((best (cons (etaf-org--mix-color page hue 0.3) (or label ink)))
        (separate (not (eq separate 'no)))
        (best-score 0)
        (weight 0.15))
    (catch 'done
      (while (<= weight 0.95)
        (let* ((fill (etaf-org--mix-color page hue weight))
               (text (or label
                         (if (> (or (etaf-org--contrast-ratio page fill) 0)
                                (or (etaf-org--contrast-ratio ink fill) 0))
                             page ink)))
               (lr (or (etaf-org--contrast-ratio text fill) 0))
               (pr (or (etaf-org--contrast-ratio fill page) 0))
               (score (if separate (min (/ lr 3.0) (/ pr 1.5)) (/ lr 3.0))))
          (when (> score best-score)
            (setq best (cons fill text) best-score score))
          (when (>= score 1.0)
            (throw 'done (cons fill text))))
        (setq weight (+ weight 0.05)))
      best)))

(defun etaf-org-typeset--mermaid-series (env page ink)
  "Return categorical color entries for ENV."
  (mapcar (lambda (key)
            (let* ((hue (etaf-org--hex-color (etaf-org--env-color env key)))
                   (fill (etaf-org-typeset--mermaid-fill page ink hue)))
              (list :hue hue :fill (car fill) :label (cdr fill))))
          etaf-org--mermaid-hues))

(defun etaf-org-typeset--mermaid-config (env)
  "Generate complete Mermaid JSON configuration matching ENV's palette."
  (let* ((colors (etaf-org-typeset--page-colors env))
         (ink (plist-get colors :ink))
         (panel (plist-get colors :panel))
         (panel2 (plist-get colors :panel2))
         (border (plist-get colors :border))
         (muted (plist-get colors :muted))
         (quote-bg (plist-get colors :quote))
         (page (plist-get colors :page))
         (danger (plist-get colors :danger))
         (base (max 8 (round (etaf-org--base-pixels))))
         (series (etaf-org-typeset--mermaid-series env page ink))
         (pick (lambda (i) (nth (mod i (length series)) series)))
         (plot-palette
          (mapconcat #'identity
                     (cl-loop for i from 0 below 6
                              for e = (funcall pick i)
                              collect (plist-get e (if (cl-evenp i) :fill :hue)))
                     ","))
         (categorical
          (append
           (cl-loop for i from 0 below 12
                    for e = (funcall pick i)
                    append (list (cons (intern (format "cScale%d" i)) (plist-get e :fill))
                                 (cons (intern (format "cScaleInv%d" i)) (plist-get e :hue))
                                 (cons (intern (format "cScalePeer%d" i)) (plist-get e :hue))
                                 (cons (intern (format "cScaleLabel%d" i)) (plist-get e :label))
                                 (cons (intern (format "pie%d" (1+ i))) (plist-get e :fill))))
           (cl-loop for i from 0 below 8
                    for e = (funcall pick i)
                    append (list (cons (intern (format "git%d" i)) (plist-get e :fill))
                                 (cons (intern (format "gitInv%d" i)) (plist-get e :hue))
                                 (cons (intern (format "gitBranchLabel%d" i)) (plist-get e :label))
                                 (cons (intern (format "fillType%d" i)) (plist-get e :fill))
                                 (cons (intern (format "actor%d" i)) (plist-get e :hue))))))
         (states
          (cl-loop for pair in '((:ok . "doneTask") (:accent . "activeTask") (:danger . "crit"))
                   for hue = (etaf-org--hex-color (etaf-org--env-color env (car pair)))
                   for fill = (car (etaf-org-typeset--mermaid-fill page ink hue ink 'no))
                   append (list (cons (intern (concat (cdr pair) "BkgColor")) fill)
                                (cons (intern (concat (cdr pair) "BorderColor")) hue)))))
    (json-encode
     `((look . "classic")
       (theme . "base")
       (htmlLabels . :json-false)
       (themeVariables
        . ((background . ,page)
           (primaryColor . ,panel) (primaryTextColor . ,ink) (primaryBorderColor . ,border)
           (secondaryColor . ,panel2) (secondaryTextColor . ,ink)
           (tertiaryColor . ,quote-bg) (tertiaryTextColor . ,ink)
           (lineColor . ,muted) (textColor . ,ink)
           (mainBkg . ,panel) (nodeBorder . ,border)
           (clusterBkg . ,(etaf-org--mix-color page ink 0.06)) (clusterBorder . ,border)
           (edgeLabelBackground . ,(etaf-org--mix-color page ink 0.06))
           (actorBkg . ,panel) (actorBorder . ,border) (actorTextColor . ,ink)
           (signalColor . ,muted) (signalTextColor . ,ink)
           (labelBoxBkgColor . ,panel) (labelBoxBorderColor . ,border) (labelTextColor . ,ink)
           (noteBkgColor . ,quote-bg) (noteTextColor . ,ink) (noteBorderColor . ,border)
           (pieStrokeColor . ,page) (pieOuterStrokeColor . ,border)
           (rowOdd . ,panel2) (rowEven . ,quote-bg)
           (sectionBkgColor . ,(etaf-org--mix-color page ink 0.04))
           (sectionBkgColor2 . ,(etaf-org--mix-color page ink 0.04))
           (altSectionBkgColor . ,page)
           (gridColor . ,(etaf-org--mix-color page ink 0.14))
           (vertLineColor . ,(etaf-org--mix-color page ink 0.14))
           (todayLineColor . ,danger)
           (taskBkgColor . ,panel) (taskBorderColor . ,border)
           (taskTextColor . ,ink) (taskTextOutsideColor . ,ink)
           (taskTextDarkColor . ,ink) (taskTextClickableColor . ,ink)
           (titleColor . ,ink) (faceColor . ,panel)
           (quadrant1Fill . ,page) (quadrant2Fill . ,page)
           (quadrant3Fill . ,page) (quadrant4Fill . ,page)
           (quadrantPointFill . ,ink) (quadrantPointTextFill . ,ink)
           (quadrantXAxisTextFill . ,muted) (quadrantYAxisTextFill . ,muted)
           (quadrantInternalBorderStrokeFill . ,border)
           (quadrantExternalBorderStrokeFill . ,border)
           (commitLabelFontSize . ,(format "%dpx" base)) (commitLabelColor . ,ink)
           (commitLabelBackground . ,page) (commitLabelBorderColor . ,border)
           (tagLabelFontSize . ,(format "%dpx" base)) (tagLabelColor . ,ink)
           (tagLabelBackground . ,panel2) (tagLabelBorder . ,border)
           (xyChart . ((backgroundColor . ,page) (titleColor . ,ink)
                       (xAxisLabelColor . ,muted) (xAxisTitleColor . ,ink)
                       (xAxisTickColor . ,muted) (xAxisLineColor . ,border)
                       (yAxisLabelColor . ,muted) (yAxisTitleColor . ,ink)
                       (yAxisTickColor . ,muted) (yAxisLineColor . ,border)
                       (plotColorPalette . ,plot-palette)
                       (dataLabelColor . ,ink) (legendTextColor . ,ink)))
           (radar . ((axisColor . ,muted) (axisStrokeWidth . 1)
                     (graticuleColor . ,(etaf-org--mix-color page ink 0.14))
                     (graticuleStrokeWidth . 1) (curveStrokeWidth . 2) (curveOpacity . 0.2)))
           (architecture . ((archEdgeColor . ,muted) (archEdgeArrowColor . ,muted)
                            (archGroupBorderColor . ,border)))
           (c4 . ((personBkg . ,panel) (personBorder . ,border)
                  (systemBkg . ,panel) (systemBorder . ,border)
                  (externalSystemBkg . ,quote-bg) (externalSystemBorder . ,border)
                  (messageTextColor . ,ink)))
           (fontFamily . ,(etaf-org-typeset--mermaid-font-family))
           (fontSize . ,(format "%dpx" base))
           ,@categorical
           ,@states))
       (flowchart . ((padding . 8) (nodeSpacing . 40) (rankSpacing . 40)
                     (wrappingWidth . 160) (useMaxWidth . t) (htmlLabels . t)))
       (sequence . ((diagramMarginX . 16) (diagramMarginY . 12)
                    (actorMargin . 40) (boxMargin . 10)
                    (actorFontSize . ,base) (messageFontSize . ,base)
                    (noteFontSize . ,base)))
       (gitGraph . ((rotateCommitLabel . :json-false)))
       (gantt . ((fontSize . ,base) (sectionFontSize . ,base)))
       (er . ((fontSize . ,base) (minEntityWidth . 60) (minEntityHeight . 40)))
       (requirement . ((fontSize . ,base) (rect_min_width . 120)))
       (state . ((fontSize . ,base) (minNodeWidth . 60)))))))

(defun etaf-org-typeset--page-cache (env)
  "Return per-page cached `(COLORS CONFIG-JSON CONFIG-HASH)' for ENV."
  (let* ((sig (list (plist-get env :background)
                    (etaf-org--env-color env :bg)
                    (etaf-org--env-color env :ink)
                    (etaf-org--base-pixels)))
         (cached (plist-get env :typeset-page)))
    (if (and cached (equal (car cached) sig))
        (cdr cached)
      (let* ((colors (etaf-org-typeset--colors env))
             (cfg (etaf-org-typeset--mermaid-config env))
             (entry (list colors cfg (secure-hash 'sha1 cfg))))
        (plist-put env :typeset-page (cons sig entry))
        entry))))

;;; ---------------------------------------------------------------------------
;;; Formula & block extraction
;;; ---------------------------------------------------------------------------

(defun etaf-org-typeset--unwrap-latex (text)
  "Unwrap outer LaTeX equation/align environments for KaTeX."
  (let ((trimmed (string-trim (or text ""))))
    (cond
     ((string-match "\\`\\\\begin{\\(?:equation\\|displaymath\\)\\*?}\\(\\(?:.\\|\n\\)*\\)\\\\end{\\(?:equation\\|displaymath\\)\\*?}\\'"
                    trimmed)
      (string-trim (match-string 1 trimmed)))
     ((string-match "\\`\\\\begin{align\\*?}\\(\\(?:.\\|\n\\)*\\)\\\\end{align\\*?}\\'" trimmed)
      (concat "\\begin{aligned}\n" (string-trim (match-string 1 trimmed)) "\n\\end{aligned}"))
     ((string-match "\\`\\\\begin{gather\\*?}\\(\\(?:.\\|\n\\)*\\)\\\\end{gather\\*?}\\'" trimmed)
      (concat "\\begin{gathered}\n" (string-trim (match-string 1 trimmed)) "\n\\end{gathered}"))
     (t trimmed))))

(defun etaf-org-typeset--block-spec (block)
  "Return `(KIND . SOURCE)' for drawable BLOCK, or nil."
  (pcase (plist-get block :type)
    ('src-block
     (let ((lang (downcase (or (plist-get block :lang) "")))
           (text (or (plist-get block :text) "")))
       (unless (string-blank-p text)
         (cond
          ((equal lang "mermaid") (cons 'mermaid text))
          ((member lang '("dot" "graphviz")) (cons 'dot text))
          ((equal lang "plantuml") (cons 'plantuml text))
          ((equal lang "svg") (cons 'svg text))))))
    ('display-math
     (let ((raw (or (plist-get block :raw) (plist-get block :text) "")))
       (unless (string-blank-p raw) (cons 'math raw))))
    ('latex-environment
     (let ((text (or (plist-get block :text) "")))
       (unless (string-blank-p text)
         (cons 'math (etaf-org-typeset--unwrap-latex text)))))
    (_ nil)))

(defun etaf-org-typeset--key (kind source env)
  "Return deterministic cache key for KIND, SOURCE and ENV."
  (let* ((page (etaf-org-typeset--page-cache env))
         (colors (nth 0 page))
         (cfg-hash (nth 2 page)))
    (secure-hash 'sha1
                 (format "%s\n%d\n%s\n%s\n%s\n%s"
                         kind etaf-org-typeset--picture-version source
                         (car colors) (cdr colors)
                         (if (eq kind 'math)
                             (format "%d/%d"
                                     (max 12 (round (etaf-org--base-pixels)))
                                     (cdr (etaf-org--cell-metrics)))
                           cfg-hash)))))

(defun etaf-org-typeset--path (kind key)
  "Return primary output path for KIND and KEY."
  (if (memq kind '(mermaid math))
      (expand-file-name (concat key ".png") etaf-org-typeset--cache-directory)
    (expand-file-name (concat key ".svg") etaf-org-typeset--diagram-directory)))

(defun etaf-org-typeset--picture (kind key)
  "Return cached picture path (preferring SVG vector) for KIND and KEY, or nil."
  (let ((primary (etaf-org-typeset--path kind key)))
    (when (file-exists-p primary)
      (if (memq kind '(mermaid math))
          (let ((vec (concat (file-name-sans-extension primary) ".svg")))
            (if (file-exists-p vec) vec primary))
        primary))))

(defun etaf-org-typeset-attach (block env)
  "Attach cached `:picture' path onto BLOCK in ENV when already on disk.
For inline `svg' source blocks, writes the validated SVG file during publish
(never during `:render')."
  (if (not etaf-org-typeset)
      block
    (if-let* ((spec (etaf-org-typeset--block-spec block))
              (kind (car spec))
              (source (cdr spec)))
        (let* ((key (etaf-org-typeset--key kind source env))
               (path (etaf-org-typeset--picture kind key)))
          (when (and (null path) (eq kind 'svg)
                     (string-match-p "<svg\\b" source))
            (make-directory etaf-org-typeset--diagram-directory t)
            (let ((dest (etaf-org-typeset--path 'svg key)))
              (with-temp-file dest (insert source))
              (etaf-org-cache-prune-directory etaf-org-typeset--diagram-directory)
              (setq path dest)))
          (if path
              (plist-put (copy-sequence block) :picture path)
            block))
      block)))

;;; ---------------------------------------------------------------------------
;;; Persistent Chromium worker & external diagram runners
;;; ---------------------------------------------------------------------------

(defun etaf-org-typeset--renderer-start (script)
  "Start or return the persistent Node/Chromium worker process for SCRIPT."
  (unless (process-live-p etaf-org-typeset--renderer)
    (let ((errors (generate-new-buffer " *etaf-org-renderer-errors*")))
      (setq etaf-org-typeset--renderer-text "")
      (setq etaf-org-typeset--renderer
            (make-process
             :name "etaf-org-renderer"
             :buffer nil
             :command (list "node" script)
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :stderr errors
             :filter #'etaf-org-typeset--renderer-filter
             :sentinel #'etaf-org-typeset--renderer-sentinel))
      (process-put etaf-org-typeset--renderer :errors errors)))
  etaf-org-typeset--renderer)

(defun etaf-org-typeset--reset-idle ()
  "Restart idle shutdown timer for the worker."
  (when (timerp etaf-org-typeset--idle-timer)
    (cancel-timer etaf-org-typeset--idle-timer))
  (setq etaf-org-typeset--idle-timer
        (run-at-time etaf-org-typeset--renderer-idle nil
                     (lambda ()
                       (setq etaf-org-typeset--idle-timer nil)
                       (when (and (process-live-p etaf-org-typeset--renderer)
                                  (zerop (hash-table-count etaf-org-typeset--requests)))
                         (delete-process etaf-org-typeset--renderer))))))

(defun etaf-org-typeset--renderer-filter (_process text)
  "Process newline-delimited JSON replies from the worker."
  (setq etaf-org-typeset--renderer-text
        (concat etaf-org-typeset--renderer-text text))
  (let ((buf etaf-org-typeset--renderer-text))
    (while (string-match "\n" buf)
      (let ((line (substring buf 0 (match-beginning 0))))
        (setq buf (substring buf (match-end 0)))
        (unless (string-blank-p line)
          (when-let* ((reply (ignore-errors (json-parse-string line :object-type 'plist)))
                      (id (plist-get reply :id))
                      ((integerp id))
                      (req (gethash id etaf-org-typeset--requests)))
            (remhash id etaf-org-typeset--requests)
            (remhash (plist-get req :key) etaf-org-typeset--running)
            (if (eq (plist-get reply :ok) t)
                (when (and (file-exists-p (etaf-org-typeset--path
                                           (plist-get req :kind)
                                           (plist-get req :key)))
                           (plist-get req :done))
                  (etaf-org-cache-prune-directory etaf-org-typeset--cache-directory)
                  (run-at-time 0 nil (plist-get req :done)))
              (when (eq (plist-get reply :fatal) t)
                (puthash (plist-get req :key)
                         (or (plist-get reply :error) "render error")
                         etaf-org-typeset--failed)))
            (etaf-org-typeset--reset-idle)))))
    (setq etaf-org-typeset--renderer-text buf)))

(defun etaf-org-typeset--renderer-sentinel (process _event)
  "Clean up pending requests if the worker exits unexpectedly."
  (when (memq (process-status process) '(exit signal))
    (setq etaf-org-typeset--renderer nil)
    (when (timerp etaf-org-typeset--idle-timer)
      (cancel-timer etaf-org-typeset--idle-timer)
      (setq etaf-org-typeset--idle-timer nil))
    (when-let* ((err-buf (process-get process :errors))
                ((buffer-live-p err-buf)))
      (kill-buffer err-buf))
    (maphash (lambda (_id req)
               (remhash (plist-get req :key) etaf-org-typeset--running))
             etaf-org-typeset--requests)
    (clrhash etaf-org-typeset--requests)))

(defun etaf-org-typeset--start-worker-job (key kind source env done)
  "Submit one Mermaid or KaTeX job to the persistent Chromium worker."
  (make-directory etaf-org-typeset--cache-directory t)
  (let* ((page (etaf-org-typeset--page-cache env))
         (colors (nth 0 page))
         (cfg (nth 1 page))
         (pc (etaf-org-typeset--page-colors env))
         (id (cl-incf etaf-org-typeset--serial))
         (opts (if (eq kind 'math)
                   (list :ink (cdr colors)
                         :pixels (max 12 (round (etaf-org--base-pixels)))
                         :cell (cdr (etaf-org--cell-metrics)))
                 (list :config cfg
                       :palette (list :page (plist-get pc :page)
                                      :ink (plist-get pc :ink)
                                      :line (plist-get pc :muted)
                                      :panel (plist-get pc :panel)
                                      :danger (plist-get pc :danger)))))
         (req (append (list :id id :kind (symbol-name kind)
                            :source source
                            :out (etaf-org-typeset--path kind key))
                      opts)))
    (puthash id (list :key key :kind kind :done done) etaf-org-typeset--requests)
    (puthash key id etaf-org-typeset--running)
    (if-let* ((script (etaf-org-typeset--renderer-script))
              (proc (ignore-errors (etaf-org-typeset--renderer-start script)))
              ((process-live-p proc)))
        (progn
          (process-send-string proc (concat (json-encode req) "\n"))
          (etaf-org-typeset--reset-idle)
          t)
      (remhash id etaf-org-typeset--requests)
      (remhash key etaf-org-typeset--running)
      nil)))

(defun etaf-org-typeset--start-external-diagram (key kind source done)
  "Run `dot -Tsvg' or `plantuml -tsvg -pipe' asynchronously for SOURCE."
  (let ((cmd (pcase kind
               ('dot (and (executable-find "dot") '("dot" "-Tsvg")))
               ('plantuml (and (executable-find "plantuml") '("plantuml" "-tsvg" "-pipe")))
               (_ nil))))
    (when cmd
      (make-directory etaf-org-typeset--diagram-directory t)
      (puthash key t etaf-org-typeset--running)
      (let ((dest (etaf-org-typeset--path kind key))
            (src-file (make-temp-file "etaf-org-diag-")))
        (with-temp-file src-file (insert source))
        (let ((args (if (eq kind 'dot)
                        (list "dot" "-Tsvg" src-file)
                      (list "sh" "-c"
                            (format "plantuml -tsvg -pipe < %s"
                                    (shell-quote-argument src-file))))))
          (etaf-process-run
           args
           :name (format "etaf-org-%s" kind)
           :timeout 20
           :callback
           (lambda (res)
             (ignore-errors (delete-file src-file))
             (remhash key etaf-org-typeset--running)
             (let ((out (plist-get res :output)))
               (if (and (eq (plist-get res :status) 'exit)
                        (eql (plist-get res :exit) 0)
                        (stringp out)
                        (string-match-p "<svg\\b" out))
                   (progn
                     (with-temp-file dest (insert out))
                     (etaf-org-cache-prune-directory etaf-org-typeset--diagram-directory)
                     (run-at-time 0 nil done))
                 (puthash key "external diagram failed" etaf-org-typeset--failed))))))))))

(defun etaf-org-typeset--notify (session)
  "Coalesce repaint of SESSION after pictures arrive."
  (when (and (buffer-live-p (plist-get session :buffer))
             (not (plist-get session :typeset-pending)))
    (plist-put session :typeset-pending t)
    (run-at-time 0.15 nil
                 (lambda ()
                   (plist-put session :typeset-pending nil)
                   (when (and (buffer-live-p (plist-get session :buffer))
                              (fboundp 'etaf-org--refresh-block-assets))
                     (etaf-org--refresh-block-assets session))))))

(defun etaf-org-typeset-request (session)
  "Queue async rendering for uncached formulas and diagrams in SESSION."
  (when (and etaf-org-typeset
             (buffer-live-p (plist-get session :buffer))
             (fboundp 'etaf-org--walk-document-blocks))
    (let ((env (etaf-org--env session))
          (wanted nil))
      (etaf-org--walk-document-blocks
       (etaf-org--read session :document)
       (lambda (block)
         (when-let* ((spec (etaf-org-typeset--block-spec block))
                     (kind (car spec))
                     (source (cdr spec))
                     ((not (eq kind 'svg)))
                     (key (etaf-org-typeset--key kind source env))
                     ((not (etaf-org-typeset--picture kind key)))
                     ((not (gethash key etaf-org-typeset--running)))
                     ((not (gethash key etaf-org-typeset--failed))))
           (push (list kind source key) wanted))))
      (when wanted
        (run-at-time
         0 nil
         (lambda ()
           (dolist (entry (nreverse wanted))
             (let ((kind (nth 0 entry))
                   (source (nth 1 entry))
                   (key (nth 2 entry)))
               (unless (or (etaf-org-typeset--picture kind key)
                           (gethash key etaf-org-typeset--running)
                           (gethash key etaf-org-typeset--failed))
                 (cond
                  ((and (memq kind '(mermaid math))
                        (etaf-org-typeset-available-p))
                   (etaf-org-typeset--start-worker-job
                    key kind source env
                    (lambda () (etaf-org-typeset--notify session))))
                  ((memq kind '(dot plantuml))
                   (etaf-org-typeset--start-external-diagram
                    key kind source
                    (lambda () (etaf-org-typeset--notify session))))))))))))))

;;; ---------------------------------------------------------------------------
;;; Rendering a cached figure
;;; ---------------------------------------------------------------------------

(defun etaf-org--typeset-figure (kind path env &optional eq-number caption)
  "Return the ETAF View for a cached formula or diagram PATH of KIND in ENV."
  (let* ((width (max 24 (or (plist-get env :width) 88)))
         (raw-px (etaf-org-typeset--image-pixels path))
         (pixels (when raw-px
                   (if (memq kind '(mermaid math))
                       (cons (/ (car raw-px) (float etaf-org-typeset--scale))
                             (/ (cdr raw-px) (float etaf-org-typeset--scale)))
                     raw-px)))
         (grid (etaf-org-typeset--grid-for-pixels pixels (- width 2)
                                                  (if (eq kind 'math) 12 28)))
         (raster (concat (file-name-sans-extension path) ".png"))
         (cell (etaf-org--cell-metrics))
         (shown (if (and (string-suffix-p ".svg" path)
                         (file-exists-p raster)
                         (when-let* ((decl (etaf-org-typeset--image-pixels raster)))
                           (<= (* (car grid) (car cell)) (car decl))))
                    raster
                  path))
         (image (etaf-node 'image
                           (list :src shown
                                 :columns (car grid)
                                 :rows (cdr grid)
                                 :adapter 'auto)
                           nil))
         (session (plist-get env :session)))
    (if (eq kind 'math)
        (let ((row (if eq-number
                       (etaf-node 'flex
                                  (list :width 'stretch :align-items 'center
                                        :justify-content 'space-between)
                                  (list (etaf-node 'box (list :width '(ch 4)) nil)
                                        image
                                        (etaf-node 'text
                                                   (list :color (etaf-org--env-color env :muted))
                                                   (list eq-number))))
                     image)))
          (etaf-node 'column
                     (list :width 'stretch :max-width (list 'ch width)
                           :cross-align 'center)
                     (list row)))
      (etaf-node 'column
                 (list :width 'stretch :max-width (list 'ch width)
                       :cross-align 'center :item-gap '(lh 0))
                 (list
                  (etaf-node 'box
                             (list :on-press
                                   (lambda ()
                                     (when (and session (fboundp 'etaf-org--activate-media))
                                       (etaf-org--activate-media session 'image path)))
                                   :role 'button :tab-index 0 :pointer 'hand
                                   :help-echo (format "%s（RET 预览/打开）"
                                                      (file-name-nondirectory path)))
                             (list image))
                  (etaf-node 'text
                             (list :color (etaf-org--env-color env :muted))
                             (list (or caption (format "▲ %s" kind)))))))))

(provide 'etaf-org-typeset)
;;; etaf-org-typeset.el ends here
