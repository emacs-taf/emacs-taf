;;; etaf-md-typeset.el --- Draw diagrams and formulas in the background -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Two block kinds carry a picture rather than prose: a fenced `mermaid' block
;; and a `$$' display formula.  The parser and the shared renderer keep them as
;; source, which is what a reader sees when the native module is absent.
;;
;; When the embedded QuickJS native dynamic module
;; (`etaf-md-typeset-native.{dylib,so}', inspired by LuciusChen/pele.el) is
;; installed, both Mermaid diagrams (via vendored Obsidian Pele + native
;; CoreText/Pango label measurement) and display formulas (via vendored MathJax
;; TeX-to-SVG) render on an embedded background thread with zero Chromium,
;; Node.js or child processes, writing standalone SVGs directly to disk cache.
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
When nil, or when the native QuickJS module is unavailable, a mermaid block and
a display formula keep their source and the plain-text rendering the shared
renderer paints.  A page never waits for a render either way: a picture that is
not cached yet appears on the repaint that follows its completion."
  :type 'boolean)

(defconst etaf-md-typeset--cache-directory
  (expand-file-name "etaf-md/typeset/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Directory holding one SVG per rendered block.")

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
  "When non-nil, use the embedded QuickJS native module when installed.")

(defconst etaf-md-typeset--native-version "1"
  "Native dynamic module ABI/content version expected by this Elisp layer.")

(defvar etaf-md-typeset--native-failed nil
  "Cons of (PATH . MTIME) when loading that native binary failed.")

(defvar etaf-md-typeset--native-loaded nil
  "Path of the loaded native typesetting module, or nil.")

(defvar etaf-md-typeset--native-hinted nil
  "Non-nil after hinting once per session about prebuilt native rendering.")

(defvar etaf-md-typeset--native-requests (make-hash-table :test #'eql)
  "Native renders in flight or queued for `etaf-md', keyed by request id.")

(defvar etaf-md-typeset--native-waiting nil
  "FIFO list of `etaf-md' native jobs waiting for a free worker slot.")

(defvar etaf-md-typeset--native-in-flight 0
  "Number of `etaf-md' jobs currently submitted to the native worker thread.")

(defconst etaf-md-typeset--native-max-in-flight 32
  "Maximum concurrent jobs pushed into the native worker queue at once.")

(defconst etaf-md-typeset--native-timeout 10000
  "Per-job timeout in milliseconds for the embedded QuickJS worker.")

(defvar etaf-md-typeset--failed (make-hash-table :test #'equal)
  "Renderer's message by block key of a block that cannot be drawn.
A key holds the source and every setting the picture depends on, so a block
stays unrendered until its source or the page changes, and one bad diagram is
not retried on every keystroke that republishes the page.")

;;; ---------------------------------------------------------------------------
;;; Backend discovery and shared native-module coordination
;;; ---------------------------------------------------------------------------

(defun etaf-md-typeset--package-root ()
  "Return the root directory of `etaf-md', or nil when running only from .eln."
  (when-let* ((entry (locate-library "etaf-md"))
              ((not (string-suffix-p ".eln" entry))))
    (file-name-directory entry)))

(defun etaf-md-typeset--native-cache-root ()
  "Return the root cache directory holding prebuilt ETAF native modules."
  (or (and (boundp 'etaf-install-native-directory)
           etaf-install-native-directory)
      (expand-file-name
       "emacs-taf/native"
       (or (let ((xdg (getenv "XDG_CACHE_HOME")))
             (and xdg (not (string-empty-p xdg)) xdg))
           (expand-file-name "~/.cache")))))

(defun etaf-md-typeset--native-module-path ()
  "Return the native typesetting module path if present in checkout or cache."
  (when (and module-file-suffix (stringp module-file-suffix))
    (let* ((root (etaf-md-typeset--package-root))
           (cache-root (etaf-md-typeset--native-cache-root))
           (name (concat "etaf-md-typeset-native" module-file-suffix))
           (candidates
            (delq nil
                  (list (and root (expand-file-name name (expand-file-name "native" root)))
                        (and root (expand-file-name name root))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-md/" etaf-md-typeset--native-version)
                                           cache-root))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-org/" etaf-md-typeset--native-version)
                                           cache-root))))))
      (cl-find-if #'file-exists-p candidates))))

(defun etaf-md--native-shared-callbacks ()
  "Return the process-wide callback table on `etaf-md-typeset-native'."
  (or (get 'etaf-md-typeset-native :callbacks)
      (put 'etaf-md-typeset-native :callbacks (make-hash-table :test #'eql))))

(defun etaf-md--native-shared-next-id ()
  "Allocate a globally unique request id across all native-typeset consumers."
  (put 'etaf-md-typeset-native :serial
       (1+ (or (get 'etaf-md-typeset-native :serial) 0))))

(defun etaf-md--native-shared-stop-timer ()
  "Stop the shared safety poll timer when no callbacks remain."
  (when-let* ((timer (get 'etaf-md-typeset-native :timer)))
    (when (timerp timer) (cancel-timer timer))
    (put 'etaf-md-typeset-native :timer nil)))

(defun etaf-md--native-shared-drain ()
  "Drain all completed jobs from the shared native QuickJS worker."
  (when (featurep 'etaf-md-typeset-native)
    (let ((callbacks (etaf-md--native-shared-callbacks))
          (limit 64)
          entry)
      (while (and (> limit 0) (setq entry (etaf-md--native-poll)))
        (cl-decf limit)
        (let* ((id (car entry))
               (cb (gethash id callbacks)))
          (remhash id callbacks)
          (when (functionp cb)
            (funcall cb (cadr entry)))))
      (when (zerop (hash-table-count callbacks))
        (etaf-md--native-shared-stop-timer))))
  (etaf-md--native-dispatch))

(defun etaf-md-typeset--ensure-native ()
  "Ensure the native QuickJS module is loaded and its shared wakeup pipe is live.
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
      (etaf-md--native-shared-callbacks)
      (unless (process-live-p (get 'etaf-md-typeset-native :channel))
        (let ((proc (make-pipe-process
                     :name "etaf-typeset-native"
                     :noquery t
                     :coding 'no-conversion
                     :filter (lambda (_p _text)
                               (when-let* ((fn (get 'etaf-md-typeset-native :drain)))
                                 (funcall fn))))))
          (put 'etaf-md-typeset-native :channel proc)
          (etaf-md--native-channel proc)))
      (unless (get 'etaf-md-typeset-native :drain)
        (put 'etaf-md-typeset-native :drain #'etaf-md--native-shared-drain))
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

(defun etaf-md-typeset-available-p ()
  "Return non-nil when this system can draw diagrams and formulas.
Uses the embedded QuickJS native module (`etaf-md-typeset-native')."
  (and etaf-md-typeset
       (etaf-md-typeset--native-available-p)))

;;; ---------------------------------------------------------------------------
;;; Colors, keys and cache lookup
;;; ---------------------------------------------------------------------------

(defun etaf-md--typeset-colors (env)
  "Return (PALETTE . INK) drawn for ENV's page."
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
                         'native)))
    (let ((cached (plist-get env :typeset-page)))
      (if (and cached (equal (car cached) signature))
          (cdr cached)
        (let* ((config-str (etaf-md--native-mermaid-options-json env))
               (page (cons (etaf-md--typeset-colors env)
                           (secure-hash 'sha1 config-str))))
          (plist-put env :typeset-page (cons signature page))
          page)))))

(defun etaf-md--typeset-key (kind source env)
  "Return the cache key of KIND drawn from SOURCE for ENV's surface."
  (let* ((page (etaf-md--typeset-page env))
         (colors (car page)))
    (secure-hash 'sha1
                 (format "native\n%s\n%d\n%s\n%s\n%s\n%s"
                         kind etaf-md-typeset--picture-version source
                         (car colors)
                         (cdr colors)
                         (if (eq kind 'math)
                             (format "%d/%d/%s"
                                     (etaf-md--typeset-pixels)
                                     (cdr (etaf-md--cell-metrics))
                                     (etaf-md--mermaid-font-family))
                           (cdr page))))))

(defun etaf-md--typeset-svg-path (key)
  "Return the SVG cache path of KEY."
  (expand-file-name (concat key ".svg") etaf-md-typeset--cache-directory))

(defun etaf-md--typeset-picture (key)
  "Return the cached SVG path for KEY, or nil when it is not drawn yet."
  (let ((vector (etaf-md--typeset-svg-path key)))
    (when (file-exists-p vector) vector)))

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
  "Upper row safety ceiling for typeset diagrams and display formulas.")

(defun etaf-md--typeset-figure (kind path env)
  "Return the View of the SVG picture at PATH for KIND in ENV."
  (let* ((width (max 24 (or (plist-get env :figure-width)
                            (plist-get env :width) 92)))
         (pixels (when-let* ((natural (ignore-errors
                                        (etaf-md--image-pixels path))))
                   (cons (/ (car natural) (float etaf-md-typeset--scale))
                         (/ (cdr natural) (float etaf-md-typeset--scale)))))
         (grid (or (etaf-md--media-grid-for-pixels
                    pixels (- width 2) etaf-md-typeset--max-rows)
                   (cons width 8)))
         (image (etaf-node 'image
                           (list :src path
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
;;; Typography and Pele/MathJax theme mapping
;;; ---------------------------------------------------------------------------

(defconst etaf-md-mermaid-fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Families a diagram falls back to when the reader's own font lacks a glyph.")

(defconst etaf-md-mermaid-mono-fonts
  '("LXGW WenKai Mono" "Menlo" "Monaco" "DejaVu Sans Mono" "monospace")
  "Monospace families for code labels inside diagrams.")

(defun etaf-md--mermaid-font-family ()
  "Return the font stack a diagram is drawn and measured with."
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
  "Return a hash table of Pele CSS custom properties derived from ENV's palette."
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

;;; ---------------------------------------------------------------------------
;;; Embedded QuickJS native worker
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
      (remhash key etaf-md-typeset--running)
      (if (and (plist-get parsed :ok) (stringp (plist-get parsed :svg)))
          (progn
            (etaf-md--typeset-write-svg key (plist-get parsed :svg))
            (etaf-md--typeset-arrived request))
        (let* ((err (plist-get parsed :error))
               (code (or (plist-get err :code) "render"))
               (msg (or (plist-get err :message) "native renderer failed"))
               (transient (member code '("timeout" "cancelled" "memory" "engine"))))
          (etaf-md--typeset-failed request msg (not transient)))))
    (etaf-md--native-dispatch)))

(defun etaf-md--native-dispatch ()
  "Submit queued native jobs up to `etaf-md-typeset--native-max-in-flight'."
  (let ((callbacks (etaf-md--native-shared-callbacks)))
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
          (puthash id (lambda (json-text)
                        (etaf-md--native-handle-result id json-text))
                   callbacks)
          (condition-case err
              (progn
                (etaf-md--native-submit
                 id kind-str source options-json etaf-md-typeset--native-timeout)
                (cl-incf etaf-md-typeset--native-in-flight))
            (error
             (remhash id callbacks)
             (remhash id etaf-md-typeset--native-requests)
             (remhash (plist-get request :key) etaf-md-typeset--running)
             (etaf-md--typeset-failed
              request (error-message-string err) nil))))))))

(defun etaf-md--native-shutdown-all ()
  "Cleanly shut down the native QuickJS worker before Emacs exits."
  (etaf-md--native-shared-stop-timer)
  (setq etaf-md-typeset--native-waiting nil
        etaf-md-typeset--native-in-flight 0)
  (clrhash etaf-md-typeset--native-requests)
  (when-let* ((callbacks (get 'etaf-md-typeset-native :callbacks)))
    (clrhash callbacks))
  (when (and (featurep 'etaf-md-typeset-native)
             (fboundp 'etaf-md--native-shutdown))
    (ignore-errors (etaf-md--native-shutdown)))
  (when-let* ((ch (get 'etaf-md-typeset-native :channel)))
    (when (process-live-p ch)
      (ignore-errors (delete-process ch)))
    (put 'etaf-md-typeset-native :channel nil)))

(add-hook 'kill-emacs-hook #'etaf-md--native-shutdown-all)

(defun etaf-md--typeset-start (key kind source env done)
  "Queue SOURCE of KIND for KEY on the embedded QuickJS worker."
  (when (etaf-md-typeset--ensure-native)
    (let* ((id (etaf-md--native-shared-next-id))
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
      (unless (timerp (get 'etaf-md-typeset-native :timer))
        (put 'etaf-md-typeset-native :timer
             (run-at-time 0.02 0.04
                          (lambda ()
                            (when-let* ((fn (get 'etaf-md-typeset-native :drain)))
                              (funcall fn))))))
      t)))

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
