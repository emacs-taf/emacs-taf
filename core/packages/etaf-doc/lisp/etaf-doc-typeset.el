;;; etaf-doc-typeset.el --- Shared native QuickJS SVG math & diagram worker -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Single process-wide QuickJS native typesetting coordinator (`etaf-md-typeset-native')
;; shared across ETAF document renderers (`etaf-md', `etaf-org', `etaf-web'),
;; plus fast zero-rasterization SVG/PNG/GIF/WebP/JPEG header dimension readers
;; and Pele/MathJax theme option builders.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc-cache)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function etaf-md--native-submit "ext:etaf-md-typeset-native" (id kind source options timeout))
(declare-function etaf-md--native-poll "ext:etaf-md-typeset-native" ())
(declare-function etaf-md--native-cancel "ext:etaf-md-typeset-native" (id))
(declare-function etaf-md--native-channel "ext:etaf-md-typeset-native" (process))
(declare-function etaf-md--native-shutdown "ext:etaf-md-typeset-native" ())
(declare-function etaf-md--native-info "ext:etaf-md-typeset-native" ())

(defconst etaf-doc-typeset--native-version "1"
  "Native dynamic module ABI/content version expected by this Elisp layer.")

(defconst etaf-doc-typeset--default-scale 2
  "Default pixel density multiplier for rendered SVGs.")

(defconst etaf-doc-typeset--max-in-flight 32
  "Maximum concurrent jobs pushed into the native QuickJS worker at once.")

(defconst etaf-doc-typeset--timeout-ms 10000
  "Default per-job timeout in milliseconds for the embedded QuickJS worker.")

(defconst etaf-doc-typeset--fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Fallback font stack for Mermaid diagrams and formulas including CJK glyphs.")

(defconst etaf-doc-typeset--mono-fonts
  '("LXGW WenKai Mono" "Menlo" "Monaco" "DejaVu Sans Mono" "monospace")
  "Monospace font stack for code labels inside diagrams.")

(defvar etaf-doc-typeset--native-failed nil
  "Cons of (PATH . MTIME) when loading that native binary failed.")

(defvar etaf-doc-typeset--native-loaded nil
  "Path of the loaded native typesetting module, or nil.")

(defvar etaf-doc-typeset--requests (make-hash-table :test #'eql)
  "Active or queued native typeset requests keyed by integer request id.")

(defvar etaf-doc-typeset--waiting nil
  "FIFO queue of native typeset entries awaiting a worker slot.")

(defvar etaf-doc-typeset--in-flight 0
  "Number of jobs currently submitted to the native QuickJS worker thread.")

(defvar etaf-doc-typeset--serial 0
  "Monotonic request id counter for native typeset jobs.")

(defvar etaf-doc-typeset--channel nil
  "Live wakeup pipe process signaled by the native QuickJS worker.")

(defvar etaf-doc-typeset--timer nil
  "Safety poll timer draining completions while native jobs are in flight.")

;;; ---------------------------------------------------------------------------
;;; Native module discovery and worker lifecycle
;;; ---------------------------------------------------------------------------

(defun etaf-doc-typeset--package-root ()
  "Return the root directory of `etaf-doc', or nil when running only from .eln."
  (when-let* ((entry (locate-library "etaf-doc"))
              ((not (string-suffix-p ".eln" entry))))
    (file-name-directory entry)))

(defun etaf-doc-typeset--native-cache-root ()
  "Return the root cache directory holding prebuilt ETAF native modules."
  (or (and (boundp 'etaf-install-native-directory)
           etaf-install-native-directory)
      (expand-file-name
       "emacs-taf/native"
       (or (let ((xdg (getenv "XDG_CACHE_HOME")))
             (and xdg (not (string-empty-p xdg)) xdg))
           (expand-file-name "~/.cache")))))

(defun etaf-doc-typeset--native-module-path ()
  "Return the native typesetting module path if present in checkout or cache.
Checks `etaf-doc/native', `~/.cache/emacs-taf/native/etaf-doc/1', and legacy
`etaf-md/1' / `etaf-org/1' cache locations for seamless upgrades."
  (when (and module-file-suffix (stringp module-file-suffix))
    (let* ((root (etaf-doc-typeset--package-root))
           (md-root (when-let* ((entry (locate-library "etaf-md"))
                                ((not (string-suffix-p ".eln" entry))))
                      (file-name-directory entry)))
           (cache-root (etaf-doc-typeset--native-cache-root))
           (name (concat "etaf-md-typeset-native" module-file-suffix))
           (candidates
            (delq nil
                  (list (and root (expand-file-name name (expand-file-name "native" root)))
                        (and root (expand-file-name name root))
                        (and md-root (expand-file-name name (expand-file-name "native" md-root)))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-doc/" etaf-doc-typeset--native-version)
                                           cache-root))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-md/" etaf-doc-typeset--native-version)
                                           cache-root))
                        (expand-file-name
                         name
                         (expand-file-name (concat "etaf-org/" etaf-doc-typeset--native-version)
                                           cache-root))))))
      (cl-find-if #'file-exists-p candidates))))

(defun etaf-doc-typeset--stop-timer ()
  "Stop the safety poll timer when no requests remain."
  (when (timerp etaf-doc-typeset--timer)
    (cancel-timer etaf-doc-typeset--timer)
    (setq etaf-doc-typeset--timer nil)))

(defun etaf-doc-typeset--write-svg (cache-dir key svg)
  "Write UTF-8 SVG text atomically into CACHE-DIR/KEY.svg and return that path."
  (make-directory cache-dir t)
  (let* ((target (expand-file-name (concat key ".svg") cache-dir))
         (tmp (make-temp-file (expand-file-name ".typeset-" cache-dir) nil ".svg"))
         (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (with-temp-file tmp (insert svg))
          (rename-file tmp target t)
          (etaf-doc-cache-prune-directory cache-dir)
          target)
      (when (file-exists-p tmp)
        (ignore-errors (delete-file tmp))))))

(defun etaf-doc-typeset--handle-result (id json-text)
  "Process one native worker completion for ID with JSON-TEXT."
  (when-let* ((req (gethash id etaf-doc-typeset--requests)))
    (remhash id etaf-doc-typeset--requests)
    (when (> etaf-doc-typeset--in-flight 0)
      (cl-decf etaf-doc-typeset--in-flight))
    (let* ((key (plist-get req :key))
           (cache-dir (plist-get req :cache-dir))
           (on-done (plist-get req :on-done))
           (on-error (plist-get req :on-error))
           (parsed (ignore-errors
                     (json-parse-string json-text
                                        :object-type 'plist
                                        :array-type 'list
                                        :false-object nil
                                        :null-object nil))))
      (if (and (plist-get parsed :ok) (stringp (plist-get parsed :svg)))
          (let ((path (etaf-doc-typeset--write-svg cache-dir key (plist-get parsed :svg))))
            (when (functionp on-done)
              (run-at-time 0 nil on-done path)))
        (let* ((err (plist-get parsed :error))
               (code (or (plist-get err :code) "render"))
               (msg (or (plist-get err :message) "native renderer failed"))
               (transient (member code '("timeout" "cancelled" "memory" "engine"))))
          (when (functionp on-error)
            (funcall on-error msg (not transient))))))
    (etaf-doc-typeset--dispatch)))

(defun etaf-doc-typeset--drain ()
  "Drain all completed jobs from the embedded QuickJS native worker."
  (when (featurep 'etaf-md-typeset-native)
    (let ((limit 64)
          entry)
      (while (and (> limit 0) (setq entry (etaf-md--native-poll)))
        (cl-decf limit)
        (etaf-doc-typeset--handle-result (car entry) (cadr entry)))
      (when (and (zerop (hash-table-count etaf-doc-typeset--requests))
                 (null etaf-doc-typeset--waiting))
        (etaf-doc-typeset--stop-timer))))
  (etaf-doc-typeset--dispatch))

(defun etaf-doc-typeset--dispatch ()
  "Submit queued native jobs up to `etaf-doc-typeset--max-in-flight'."
  (while (and etaf-doc-typeset--waiting
              (< etaf-doc-typeset--in-flight etaf-doc-typeset--max-in-flight))
    (let* ((entry (pop etaf-doc-typeset--waiting))
           (id (nth 0 entry))
           (kind-str (nth 1 entry))
           (source (nth 2 entry))
           (options-json (nth 3 entry))
           (req (gethash id etaf-doc-typeset--requests)))
      (when req
        (condition-case err
            (progn
              (etaf-md--native-submit
               id kind-str source options-json etaf-doc-typeset--timeout-ms)
              (cl-incf etaf-doc-typeset--in-flight))
          (error
           (remhash id etaf-doc-typeset--requests)
           (when-let* ((on-error (plist-get req :on-error)))
             (funcall on-error (error-message-string err) nil))))))))

(defun etaf-doc-typeset--ensure-native ()
  "Ensure the native QuickJS module is loaded and its wakeup pipe is live."
  (when module-file-suffix
    (unless (featurep 'etaf-md-typeset-native)
      (when-let* ((path (etaf-doc-typeset--native-module-path))
                  (mtime (file-attribute-modification-time (file-attributes path))))
        (unless (and (consp etaf-doc-typeset--native-failed)
                     (equal (car etaf-doc-typeset--native-failed) path)
                     (equal (cdr etaf-doc-typeset--native-failed) mtime))
          (condition-case err
              (progn
                (load path nil t t)
                (when (featurep 'etaf-md-typeset-native)
                  (setq etaf-doc-typeset--native-loaded path
                        etaf-doc-typeset--native-failed nil)))
            (error
             (setq etaf-doc-typeset--native-failed (cons path mtime))
             (message "etaf-doc native typeset module could not be loaded: %s"
                      (error-message-string err)))))))
    (when (featurep 'etaf-md-typeset-native)
      (unless etaf-doc-typeset--native-loaded
        (setq etaf-doc-typeset--native-loaded (or (etaf-doc-typeset--native-module-path) t)))
      (unless (process-live-p etaf-doc-typeset--channel)
        (let ((proc (make-pipe-process
                     :name "etaf-doc-typeset-native"
                     :noquery t
                     :coding 'no-conversion
                     :filter (lambda (_p _text) (etaf-doc-typeset--drain)))))
          (setq etaf-doc-typeset--channel proc)
          (etaf-md--native-channel proc)))
      t)))

(defun etaf-doc-typeset--shutdown ()
  "Cleanly shut down the shared native QuickJS worker before Emacs exits."
  (etaf-doc-typeset--stop-timer)
  (setq etaf-doc-typeset--waiting nil
        etaf-doc-typeset--in-flight 0)
  (clrhash etaf-doc-typeset--requests)
  (when (and (featurep 'etaf-md-typeset-native)
             (fboundp 'etaf-md--native-shutdown))
    (ignore-errors (etaf-md--native-shutdown)))
  (when (process-live-p etaf-doc-typeset--channel)
    (ignore-errors (delete-process etaf-doc-typeset--channel)))
  (setq etaf-doc-typeset--channel nil))

(add-hook 'kill-emacs-hook #'etaf-doc-typeset--shutdown)

(defun etaf-doc-typeset-available-p ()
  "Return non-nil when the embedded QuickJS native typesetting module is ready."
  (and (etaf-doc-typeset--ensure-native) t))

(defun etaf-doc-typeset-info ()
  "Return native QuickJS engine metadata plist when loaded, else nil."
  (when (and (etaf-doc-typeset--ensure-native)
             (fboundp 'etaf-md--native-info))
    (ignore-errors (etaf-md--native-info))))

(defun etaf-doc-typeset-request (key kind source options-json cache-dir on-done &optional on-error)
  "Queue SOURCE of KIND (`mermaid' or `math') for KEY on the QuickJS worker.
Writes the rendered SVG to CACHE-DIR/KEY.svg and invokes `(ON-DONE PATH)' on
success, or `(ON-ERROR MESSAGE FATAL-P)' on failure."
  (when (etaf-doc-typeset--ensure-native)
    (let ((id (cl-incf etaf-doc-typeset--serial))
          (kind-str (if (symbolp kind) (symbol-name kind) (format "%s" kind))))
      (puthash id (list :key key
                        :kind kind
                        :cache-dir cache-dir
                        :on-done on-done
                        :on-error on-error)
               etaf-doc-typeset--requests)
      (setq etaf-doc-typeset--waiting
            (nconc etaf-doc-typeset--waiting
                   (list (list id kind-str source options-json))))
      (etaf-doc-typeset--dispatch)
      (unless (timerp etaf-doc-typeset--timer)
        (setq etaf-doc-typeset--timer
              (run-at-time 0.02 0.04 #'etaf-doc-typeset--drain)))
      t)))

;;; ---------------------------------------------------------------------------
;;; Shared typography and Pele/MathJax theme option builder
;;; ---------------------------------------------------------------------------

(defun etaf-doc-typeset--font-family ()
  "Return the proportional font stack for Mermaid and MathJax rendering."
  (let* ((family (ignore-errors (face-attribute 'default :family nil t)))
         (names (if (and (stringp family)
                         (not (string-empty-p family))
                         (not (string= family "default")))
                    (cons family etaf-doc-typeset--fonts)
                  etaf-doc-typeset--fonts)))
    (mapconcat #'identity (delete-dups names) ", ")))

(defun etaf-doc-typeset--mono-font-family ()
  "Return the monospace font stack for diagram code labels."
  (mapconcat #'identity etaf-doc-typeset--mono-fonts ", "))

(defun etaf-doc-typeset--pele-theme (palette)
  "Build a Pele CSS custom-property hash table from hex PALETTE plist."
  (let* ((page (plist-get palette :page))
         (ink (plist-get palette :ink))
         (muted (plist-get palette :muted))
         (border (plist-get palette :border))
         (panel (plist-get palette :panel))
         (panel2 (plist-get palette :panel2))
         (accent (plist-get palette :accent))
         (ok (plist-get palette :ok))
         (warn (plist-get palette :warn))
         (important (plist-get palette :important))
         (danger (plist-get palette :danger))
         (line (and muted ink (etaf-ui-color-mix muted ink 0.35)))
         (stroke (and border muted (etaf-ui-color-mix border muted 0.35)))
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
               ("--pele-series-6" . ,(and accent ok (etaf-ui-color-mix accent ok 0.5)))
               ("--pele-series-7" . ,(and warn danger (etaf-ui-color-mix warn danger 0.5)))
               ("--pele-series-8" . ,(and important danger (etaf-ui-color-mix important danger 0.5)))))
      (when (cdr pair)
        (puthash (car pair) (cdr pair) table)))
    table))

(defun etaf-doc-typeset-options-json (kind palette &optional options)
  "Return the JSON options string for KIND (`mermaid' or `math') from PALETTE.
PALETTE is a plist of `#rrggbb' role colors (`:page', `:ink', `:muted',
`:border', `:panel', `:panel2', `:accent', `:ok', `:warn', `:important',
`:danger').  OPTIONS accepts `:font-size', `:pixels', `:cell-height', `:scale',
`:font-family' and `:mono-family'."
  (let* ((scale (or (plist-get options :scale) etaf-doc-typeset--default-scale))
         (font (or (plist-get options :font-family) (etaf-doc-typeset--font-family)))
         (mono (or (plist-get options :mono-family) (etaf-doc-typeset--mono-font-family))))
    (if (eq kind 'math)
        (json-serialize
         `((ink . ,(or (plist-get palette :ink) "#1f2328"))
           (pixels . ,(max 12 (round (or (plist-get options :pixels)
                                         (plist-get options :font-size)
                                         16))))
           (cell . ,(max 1 (round (or (plist-get options :cell-height) 20))))
           (scale . ,scale)
           (fontFamily . ,font))
         :false-object :false)
      (json-serialize
       `((fontSize . ,(max 10 (round (or (plist-get options :font-size) 15))))
         (fontFamily . ,font)
         (fontFamilyMono . ,mono)
         (measureText . t)
         (transparentBackground . t)
         (scale . ,scale)
         (theme . ,(etaf-doc-typeset--pele-theme palette)))
       :false-object :false))))

;;; ---------------------------------------------------------------------------
;;; Header-only image dimension reader and grid fitting
;;; ---------------------------------------------------------------------------

(defun etaf-doc-typeset--svg-pixels (path)
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

(defun etaf-doc-typeset--raster-pixels (path)
  "Read `(WIDTH . HEIGHT)' from PNG, GIF, WebP or JPEG headers at PATH, or nil."
  (when (and (stringp path) (file-readable-p path))
    (ignore-errors
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path nil 0 65536)
        (let ((size (buffer-size)))
          (cond
           ((and (>= size 24)
                 (equal (buffer-substring-no-properties 1 9)
                        "\x89PNG\r\n\x1a\n"))
            (let ((w (+ (ash (char-after 17) 24) (ash (char-after 18) 16)
                        (ash (char-after 19) 8) (char-after 20)))
                  (h (+ (ash (char-after 21) 24) (ash (char-after 22) 16)
                        (ash (char-after 23) 8) (char-after 24))))
              (when (and (> w 0) (> h 0)) (cons w h))))
           ((and (>= size 10)
                 (member (buffer-substring-no-properties 1 7) '("GIF87a" "GIF89a")))
            (let ((w (+ (char-after 7) (ash (char-after 8) 8)))
                  (h (+ (char-after 9) (ash (char-after 10) 8))))
              (when (and (> w 0) (> h 0)) (cons w h))))
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
           ((and (>= size 4)
                 (= (char-after 1) #xff)
                 (= (char-after 2) #xd8))
            (let ((pos 3) (found nil))
              (while (and (not found) (< (1+ pos) size))
                (while (and (< pos size) (/= (char-after pos) #xff))
                  (setq pos (1+ pos)))
                (while (and (< pos size) (= (char-after pos) #xff))
                  (setq pos (1+ pos)))
                (when (< pos size)
                  (let ((marker (char-after pos)))
                    (setq pos (1+ pos))
                    (cond
                     ((or (= marker #x01) (and (>= marker #xd0) (<= marker #xd9))) nil)
                     ((and (memq marker '(#xc0 #xc1 #xc2 #xc3 #xc5 #xc6 #xc7
                                               #xc9 #xca #xcb #xcd #xce #xcf))
                           (<= (+ pos 6) size))
                      (let ((h (+ (ash (char-after (+ pos 3)) 8) (char-after (+ pos 4))))
                            (w (+ (ash (char-after (+ pos 5)) 8) (char-after (+ pos 6)))))
                        (when (and (> w 0) (> h 0)) (setq found (cons w h)))))
                     ((<= (1+ pos) size)
                      (let ((len (+ (ash (char-after pos) 8) (char-after (1+ pos)))))
                        (setq pos (if (< len 2) size (+ pos len)))))
                     (t (setq pos size))))))
              found))))))))

(defun etaf-doc-typeset-image-pixels (path)
  "Return `(WIDTH . HEIGHT)' in pixels for PATH via fast header inspection."
  (let ((ext (downcase (or (file-name-extension (or path "")) ""))))
    (or (pcase ext
          ("svg" (etaf-doc-typeset--svg-pixels path))
          ((or "png" "gif" "webp" "jpg" "jpeg")
           (or (and (display-graphic-p) (file-readable-p path)
                    (ignore-errors (image-size (create-image path) t)))
               (etaf-doc-typeset--raster-pixels path)))
          (_ nil))
        (when (and path (file-readable-p path))
          (ignore-errors (image-size (create-image path) t))))))

(defun etaf-doc-typeset-grid-for-pixels (pixels max-columns &optional max-rows cell-metrics)
  "Return `(COLUMNS . ROWS)' fitting PIXELS inside MAX-COLUMNS and MAX-ROWS.
CELL-METRICS is an optional `(CHAR-WIDTH . LINE-HEIGHT)' cons; defaults to the
current frame's display metrics."
  (if (or (not (consp pixels))
          (not (numberp (car pixels)))
          (not (numberp (cdr pixels))))
      (cons (min max-columns 48) (min (or max-rows 14) 14))
    (let* ((metrics (or cell-metrics
                        (let ((dm (etaf-display-metrics)))
                          (cons (max 1 (or (plist-get dm :char-width) 8))
                                (max 1 (or (plist-get dm :line-height) 16))))))
           (cw (float (max 1 (car metrics))))
           (ch (float (max 1 (cdr metrics))))
           (nw (max 1.0 (float (car pixels))))
           (nh (max 1.0 (float (cdr pixels))))
           (fitted-w (min nw (* (max 4 max-columns) cw)))
           (fitted-h (* nh (/ fitted-w nw)))
           (cap-h (if max-rows (min fitted-h (* max-rows ch)) fitted-h))
           (scale (/ cap-h nh))
           (rows (max 1 (round (/ (* nh scale) ch))))
           (cols (max 1 (min max-columns (round (/ (* nw scale) cw))))))
      (cons cols rows))))

(provide 'etaf-doc-typeset)
;;; etaf-doc-typeset.el ends here
