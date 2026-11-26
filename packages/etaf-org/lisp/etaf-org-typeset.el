;;; etaf-org-typeset.el --- Native QuickJS SVG math & diagram rendering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Draws display formulas (`$$...$$', `\[...\]', LaTeX environments) and
;; Mermaid diagrams via the embedded QuickJS native dynamic module
;; (`etaf-md-typeset-native.{dylib,so}', Pele + MathJax, zero browser / Node.js)
;; plus external `dot'/`graphviz', `plantuml' and inline `svg' blocks into
;; bounded LRU disk caches.  Finished pictures repaint only their owning block.

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
(declare-function etaf-md--native-submit "ext:etaf-md-typeset-native" (id kind source options timeout))
(declare-function etaf-md--native-poll "ext:etaf-md-typeset-native" ())
(declare-function etaf-md--native-channel "ext:etaf-md-typeset-native" (process))
(declare-function etaf-md--native-shutdown "ext:etaf-md-typeset-native" ())
(declare-function etaf-md--native-info "ext:etaf-md-typeset-native" ())
(declare-function etaf-org--env "etaf-org-model" (session))
(declare-function etaf-org--read "etaf-org-model" (session key))
(declare-function etaf-org--refresh-block-assets "etaf-org-model" (session))
(declare-function etaf-org--walk-document-blocks "etaf-org-model" (document fn))
(declare-function etaf-org--activate-media "etaf-org-model" (session kind path))

(defgroup etaf-org-typeset nil
  "Formulas and diagrams drawn asynchronously."
  :group 'etaf-org)

(defcustom etaf-org-typeset t
  "Whether display formulas and diagram source blocks are drawn as pictures.
When nil, or when the native QuickJS module is unavailable, blocks keep their
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
  "Directory holding cached SVG files for formulas and Mermaid diagrams.")

(defconst etaf-org-typeset--diagram-directory
  (expand-file-name "diagrams/" etaf-org-cache--root-directory)
  "Directory holding cached SVG files for Graphviz/PlantUML/inline SVG blocks.")

(defconst etaf-org-typeset--scale 2
  "Pixels per point used when sizing rendered SVGs.")

(defconst etaf-org-typeset--picture-version 8
  "Cache-busting pipeline version.")

(defconst etaf-org-typeset--native-version "1"
  "Native dynamic module ABI/content version expected by this Elisp layer.")

(defconst etaf-org-typeset--native-timeout 10000
  "Per-job timeout in milliseconds for the embedded QuickJS worker.")

(defconst etaf-org-typeset--native-max-in-flight 32
  "Maximum concurrent native jobs submitted from `etaf-org' at once.")

(defvar etaf-org-typeset--running (make-hash-table :test #'equal)
  "Render jobs currently in flight, keyed by cache key.")

(defvar etaf-org-typeset--failed (make-hash-table :test #'equal)
  "Fatal parse/render errors keyed by cache key so bad blocks are not retried.")

(defvar etaf-org-typeset--native-failed nil
  "Cons of (PATH . MTIME) when loading that native binary failed.")

(defvar etaf-org-typeset--native-loaded nil
  "Path of the loaded native typesetting module, or nil.")

(defvar etaf-org-typeset--native-hinted nil
  "Non-nil after hinting once per session about prebuilt native rendering.")

(defvar etaf-org-typeset--native-requests (make-hash-table :test #'eql)
  "Native renders in flight or queued for `etaf-org', keyed by request id.")

(defvar etaf-org-typeset--native-waiting nil
  "FIFO list of `etaf-org' native jobs waiting for a free worker slot.")

(defvar etaf-org-typeset--native-in-flight 0
  "Number of `etaf-org' jobs currently submitted to the native worker thread.")

;;; ---------------------------------------------------------------------------
;;; Shared native QuickJS module discovery and coordination
;;; ---------------------------------------------------------------------------

(defun etaf-org-typeset--package-root ()
  "Return the root directory of `etaf-org', or nil when running only from .eln."
  (when-let* ((entry (locate-library "etaf-org"))
              ((not (string-suffix-p ".eln" entry))))
    (file-name-directory entry)))

(defun etaf-org-typeset--native-cache-root ()
  "Return the root cache directory holding prebuilt ETAF native modules."
  (or (and (boundp 'etaf-install-native-directory)
           etaf-install-native-directory)
      (expand-file-name
       "emacs-taf/native"
       (or (let ((xdg (getenv "XDG_CACHE_HOME")))
             (and xdg (not (string-empty-p xdg)) xdg))
           (expand-file-name "~/.cache")))))

(defun etaf-org-typeset--native-module-path ()
  "Return the native typesetting module path if present in checkout or cache."
  (when (and module-file-suffix (stringp module-file-suffix))
    (let* ((root (etaf-org-typeset--package-root))
           (sibling (and root
                         (expand-file-name "../etaf-md/native"
                                           (directory-file-name root))))
           (cache-root (etaf-org-typeset--native-cache-root))
           (name (concat "etaf-md-typeset-native" module-file-suffix))
           (candidates
            (delq nil
                  (list (and root (expand-file-name name (expand-file-name "native" root)))
                        (and root (expand-file-name name root))
                        (and sibling (expand-file-name name sibling))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-org/" etaf-org-typeset--native-version)
                                           cache-root))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-md/" etaf-org-typeset--native-version)
                                           cache-root))))))
      (cl-find-if #'file-exists-p candidates))))

(defun etaf-org-typeset--shared-callbacks ()
  "Return the process-wide callback table on `etaf-md-typeset-native'."
  (or (get 'etaf-md-typeset-native :callbacks)
      (put 'etaf-md-typeset-native :callbacks (make-hash-table :test #'eql))))

(defun etaf-org-typeset--shared-next-id ()
  "Allocate a globally unique request id across all native-typeset consumers."
  (put 'etaf-md-typeset-native :serial
       (1+ (or (get 'etaf-md-typeset-native :serial) 0))))

(defun etaf-org-typeset--shared-stop-timer ()
  "Stop the shared safety poll timer when no callbacks remain."
  (when-let* ((timer (get 'etaf-md-typeset-native :timer)))
    (when (timerp timer) (cancel-timer timer))
    (put 'etaf-md-typeset-native :timer nil)))

(defun etaf-org-typeset--shared-drain ()
  "Drain all completed jobs from the shared native QuickJS worker."
  (when (featurep 'etaf-md-typeset-native)
    (let ((callbacks (etaf-org-typeset--shared-callbacks))
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
        (etaf-org-typeset--shared-stop-timer))))
  (etaf-org-typeset--native-dispatch))

(defun etaf-org-typeset--ensure-native ()
  "Ensure the native QuickJS module is loaded and its shared wakeup pipe is live."
  (when module-file-suffix
    (unless (featurep 'etaf-md-typeset-native)
      (when-let* ((path (etaf-org-typeset--native-module-path))
                  (mtime (file-attribute-modification-time (file-attributes path))))
        (unless (and (consp etaf-org-typeset--native-failed)
                     (equal (car etaf-org-typeset--native-failed) path)
                     (equal (cdr etaf-org-typeset--native-failed) mtime))
          (condition-case err
              (progn
                (load path nil t t)
                (when (featurep 'etaf-md-typeset-native)
                  (setq etaf-org-typeset--native-loaded path
                        etaf-org-typeset--native-failed nil)))
            (error
             (setq etaf-org-typeset--native-failed (cons path mtime))
             (message "etaf-org native typeset module could not be loaded: %s"
                      (error-message-string err)))))))
    (when (featurep 'etaf-md-typeset-native)
      (unless etaf-org-typeset--native-loaded
        (setq etaf-org-typeset--native-loaded (or (etaf-org-typeset--native-module-path) t)))
      (etaf-org-typeset--shared-callbacks)
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
        (put 'etaf-md-typeset-native :drain #'etaf-org-typeset--shared-drain))
      t)))

(defun etaf-org-typeset--native-info ()
  "Return engine metadata plist when the native module is loaded, else nil."
  (when (and etaf-org-typeset
             (etaf-org-typeset--ensure-native)
             (fboundp 'etaf-md--native-info))
    (ignore-errors (etaf-md--native-info))))

(defun etaf-org-typeset-available-p ()
  "Return non-nil when the embedded QuickJS native module can draw Mermaid/math."
  (and etaf-org-typeset
       (etaf-org-typeset--ensure-native)))

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
;;; Typography and Pele/MathJax theme mapping
;;; ---------------------------------------------------------------------------

(defconst etaf-org-mermaid-fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Fallback font stack for Mermaid labels including CJK glyphs.")

(defconst etaf-org-mermaid-mono-fonts
  '("LXGW WenKai Mono" "Menlo" "Monaco" "DejaVu Sans Mono" "monospace")
  "Monospace families for code labels inside diagrams.")

(defun etaf-org-typeset--mermaid-font-family ()
  "Return the font stack for Mermaid and MathJax drawings."
  (let* ((family (ignore-errors (face-attribute 'default :family nil t)))
         (names (if (and (stringp family)
                         (not (string-empty-p family))
                         (not (string= family "default")))
                    (cons family etaf-org-mermaid-fonts)
                  etaf-org-mermaid-fonts)))
    (mapconcat #'identity (delete-dups names) ", ")))

(defun etaf-org-typeset--mermaid-mono-font-family ()
  "Return the monospace font stack for diagram code labels."
  (mapconcat #'identity etaf-org-mermaid-mono-fonts ", "))

(defun etaf-org-typeset--page-colors (env)
  "Return ENV's hex page colors keyed by role."
  (let ((role (lambda (k) (etaf-org--hex-color (etaf-org--env-color env k)))))
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

(defun etaf-org-typeset--pele-theme (env)
  "Return a hash table of Pele CSS custom properties derived from ENV."
  (let* ((colors (etaf-org-typeset--page-colors env))
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
         (line (etaf-org--mix-color muted ink 0.35))
         (stroke (etaf-org--mix-color border muted 0.35))
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
               ("--pele-series-6" . ,(etaf-org--mix-color accent ok 0.5))
               ("--pele-series-7" . ,(etaf-org--mix-color warn danger 0.5))
               ("--pele-series-8" . ,(etaf-org--mix-color important danger 0.5))))
      (when (cdr pair)
        (puthash (car pair) (cdr pair) table)))
    table))

(defun etaf-org-typeset--native-mermaid-options-json (env)
  "Return the JSON options string passed to the native QuickJS Pele engine."
  (let ((base (max 10 (round (etaf-org--base-pixels)))))
    (json-serialize
     `((fontSize . ,base)
       (fontFamily . ,(etaf-org-typeset--mermaid-font-family))
       (fontFamilyMono . ,(etaf-org-typeset--mermaid-mono-font-family))
       (measureText . t)
       (transparentBackground . t)
       (scale . ,etaf-org-typeset--scale)
       (theme . ,(etaf-org-typeset--pele-theme env)))
     :false-object :false)))

(defun etaf-org-typeset--native-math-options-json (env)
  "Return the JSON options string passed to the native QuickJS MathJax engine."
  (json-serialize
   `((ink . ,(cdr (etaf-org-typeset--colors env)))
     (pixels . ,(max 12 (round (etaf-org--base-pixels))))
     (cell . ,(cdr (etaf-org--cell-metrics)))
     (scale . ,etaf-org-typeset--scale)
     (fontFamily . ,(etaf-org-typeset--mermaid-font-family)))
   :false-object :false))

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
             (cfg (etaf-org-typeset--native-mermaid-options-json env))
             (entry (list colors cfg (secure-hash 'sha1 cfg))))
        (plist-put env :typeset-page (cons sig entry))
        entry))))

;;; ---------------------------------------------------------------------------
;;; Formula & block extraction
;;; ---------------------------------------------------------------------------

(defun etaf-org-typeset--unwrap-latex (text)
  "Unwrap outer LaTeX equation/align environments for MathJax."
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
                 (format "native\n%s\n%d\n%s\n%s\n%s\n%s"
                         kind etaf-org-typeset--picture-version source
                         (car colors) (cdr colors)
                         (if (eq kind 'math)
                             (format "%d/%d/%s"
                                     (max 12 (round (etaf-org--base-pixels)))
                                     (cdr (etaf-org--cell-metrics))
                                     (etaf-org-typeset--mermaid-font-family))
                           cfg-hash)))))

(defun etaf-org-typeset--path (kind key)
  "Return primary SVG cache path for KIND and KEY."
  (if (memq kind '(mermaid math))
      (expand-file-name (concat key ".svg") etaf-org-typeset--cache-directory)
    (expand-file-name (concat key ".svg") etaf-org-typeset--diagram-directory)))

(defun etaf-org-typeset--picture (kind key)
  "Return cached SVG path for KIND and KEY, or nil."
  (let ((primary (etaf-org-typeset--path kind key)))
    (when (file-exists-p primary) primary)))

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
;;; Embedded QuickJS worker & external diagram runners (dot / plantuml)
;;; ---------------------------------------------------------------------------

(defun etaf-org-typeset--write-svg (kind key svg)
  "Write UTF-8 SVG text atomically to KIND/KEY's cache path."
  (make-directory etaf-org-typeset--cache-directory t)
  (let* ((target (etaf-org-typeset--path kind key))
         (tmp (make-temp-file
               (expand-file-name ".typeset-" etaf-org-typeset--cache-directory)
               nil ".svg"))
         (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file tmp (insert svg))
          (rename-file tmp target t)
          target)
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun etaf-org-typeset--native-handle-result (id json-text)
  "Process one native worker completion for ID with JSON-TEXT."
  (when-let* ((req (gethash id etaf-org-typeset--native-requests)))
    (remhash id etaf-org-typeset--native-requests)
    (when (> etaf-org-typeset--native-in-flight 0)
      (cl-decf etaf-org-typeset--native-in-flight))
    (let* ((key (plist-get req :key))
           (kind (plist-get req :kind))
           (parsed (ignore-errors
                     (json-parse-string json-text
                                        :object-type 'plist
                                        :array-type 'list
                                        :false-object nil
                                        :null-object nil))))
      (remhash key etaf-org-typeset--running)
      (if (and (plist-get parsed :ok) (stringp (plist-get parsed :svg)))
          (progn
            (etaf-org-typeset--write-svg kind key (plist-get parsed :svg))
            (etaf-org-cache-prune-directory etaf-org-typeset--cache-directory)
            (when (plist-get req :done)
              (run-at-time 0 nil (plist-get req :done))))
        (let* ((err (plist-get parsed :error))
               (code (or (plist-get err :code) "render"))
               (msg (or (plist-get err :message) "native renderer failed"))
               (transient (member code '("timeout" "cancelled" "memory" "engine"))))
          (unless transient
            (puthash key msg etaf-org-typeset--failed)))))
    (etaf-org-typeset--native-dispatch)))

(defun etaf-org-typeset--native-dispatch ()
  "Submit queued `etaf-org' native jobs up to the concurrency limit."
  (let ((callbacks (etaf-org-typeset--shared-callbacks)))
    (while (and etaf-org-typeset--native-waiting
                (< etaf-org-typeset--native-in-flight
                   etaf-org-typeset--native-max-in-flight))
      (let* ((entry (pop etaf-org-typeset--native-waiting))
             (id (nth 0 entry))
             (kind-str (nth 1 entry))
             (source (nth 2 entry))
             (options-json (nth 3 entry))
             (req (gethash id etaf-org-typeset--native-requests)))
        (when req
          (puthash id (lambda (json-text)
                        (etaf-org-typeset--native-handle-result id json-text))
                   callbacks)
          (condition-case err
              (progn
                (etaf-md--native-submit
                 id kind-str source options-json etaf-org-typeset--native-timeout)
                (cl-incf etaf-org-typeset--native-in-flight))
            (error
             (remhash id callbacks)
             (remhash id etaf-org-typeset--native-requests)
             (remhash (plist-get req :key) etaf-org-typeset--running)
             (puthash (plist-get req :key) (error-message-string err)
                      etaf-org-typeset--failed))))))))

(defun etaf-org-typeset--native-shutdown-all ()
  "Cleanly shut down the shared native QuickJS worker before Emacs exits."
  (etaf-org-typeset--shared-stop-timer)
  (setq etaf-org-typeset--native-waiting nil
        etaf-org-typeset--native-in-flight 0)
  (clrhash etaf-org-typeset--native-requests)
  (when-let* ((callbacks (get 'etaf-md-typeset-native :callbacks)))
    (clrhash callbacks))
  (when (and (featurep 'etaf-md-typeset-native)
             (fboundp 'etaf-md--native-shutdown))
    (ignore-errors (etaf-md--native-shutdown)))
  (when-let* ((ch (get 'etaf-md-typeset-native :channel)))
    (when (process-live-p ch)
      (ignore-errors (delete-process ch)))
    (put 'etaf-md-typeset-native :channel nil)))

(add-hook 'kill-emacs-hook #'etaf-org-typeset--native-shutdown-all)

(defun etaf-org-typeset--start-native-job (key kind source env done)
  "Queue one Mermaid or MathJax job on the embedded QuickJS worker."
  (when (etaf-org-typeset--ensure-native)
    (let* ((id (etaf-org-typeset--shared-next-id))
           (kind-str (symbol-name kind))
           (options-json (if (eq kind 'math)
                             (etaf-org-typeset--native-math-options-json env)
                           (etaf-org-typeset--native-mermaid-options-json env))))
      (puthash id (list :key key :kind kind :done done)
               etaf-org-typeset--native-requests)
      (puthash key id etaf-org-typeset--running)
      (setq etaf-org-typeset--native-waiting
            (nconc etaf-org-typeset--native-waiting
                   (list (list id kind-str source options-json))))
      (etaf-org-typeset--native-dispatch)
      (unless (timerp (get 'etaf-md-typeset-native :timer))
        (put 'etaf-md-typeset-native :timer
             (run-at-time 0.02 0.04
                          (lambda ()
                            (when-let* ((fn (get 'etaf-md-typeset-native :drain)))
                              (funcall fn))))))
      t)))

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
                  ((memq kind '(mermaid math))
                   (if (etaf-org-typeset-available-p)
                       (etaf-org-typeset--start-native-job
                        key kind source env
                        (lambda () (etaf-org-typeset--notify session)))
                     (when (and (not noninteractive)
                                (not etaf-org-typeset--native-hinted))
                       (setq etaf-org-typeset--native-hinted t)
                       (message "etaf-org: Mermaid/math kept as source; run M-x etaf-install-native to enable fast zero-browser SVG rendering."))))
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
         (image (etaf-node 'image
                           (list :src path
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
