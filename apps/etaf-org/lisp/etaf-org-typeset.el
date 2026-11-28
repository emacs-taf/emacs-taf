;;; etaf-org-typeset.el --- Native QuickJS SVG math & diagram rendering -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Org adapter over `etaf-doc-typeset' for Mermaid diagrams and MathJax display
;; formulas via the shared QuickJS native worker, plus external `dot'/`graphviz',
;; `plantuml' and inline `svg' source blocks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-org-cache)
(require 'etaf-org-theme)
(require 'etaf-org-env)

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

(defvar etaf-org-typeset--running (make-hash-table :test #'equal)
  "Render jobs currently in flight, keyed by cache key.")

(defvar etaf-org-typeset--failed (make-hash-table :test #'equal)
  "Fatal parse/render errors keyed by cache key so bad blocks are not retried.")

(defvar etaf-org-typeset--native-hinted nil
  "Non-nil after hinting once per session about prebuilt native rendering.")

(defun etaf-org-typeset--native-info ()
  "Return engine metadata plist when the native module is loaded, else nil."
  (when etaf-org-typeset
    (etaf-doc-typeset-info)))

(defun etaf-org-typeset-available-p ()
  "Return non-nil when the embedded QuickJS native module can draw Mermaid/math."
  (and etaf-org-typeset
       (etaf-doc-typeset-available-p)))

(defun etaf-org-typeset--image-pixels (path)
  "Return `(WIDTH . HEIGHT)' in pixels for PATH via fast header inspection."
  (etaf-doc-typeset-image-pixels path))

(defun etaf-org-typeset--grid-for-pixels (pixels max-columns &optional max-rows)
  "Return `(COLUMNS . ROWS)' fitting PIXELS inside MAX-COLUMNS and MAX-ROWS."
  (etaf-doc-typeset-grid-for-pixels
   pixels max-columns max-rows (etaf-org--cell-metrics)))

;;; ---------------------------------------------------------------------------
;;; Typography and Pele/MathJax theme mapping
;;; ---------------------------------------------------------------------------

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

(defun etaf-org-typeset--native-mermaid-options-json (env)
  "Return the JSON options string passed to the native QuickJS Pele engine."
  (etaf-doc-typeset-options-json
   'mermaid (etaf-org-typeset--page-colors env)
   (list :font-size (max 10 (round (etaf-org--base-pixels)))
         :scale etaf-org-typeset--scale)))

(defun etaf-org-typeset--native-math-options-json (env)
  "Return the JSON options string passed to the native QuickJS MathJax engine."
  (etaf-doc-typeset-options-json
   'math (etaf-org-typeset--page-colors env)
   (list :pixels (max 12 (round (etaf-org--base-pixels)))
         :cell-height (cdr (etaf-org--cell-metrics))
         :scale etaf-org-typeset--scale)))

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
                                     (etaf-org-typeset--native-math-options-json env))
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
  "Attach cached `:picture' path onto BLOCK in ENV when already on disk."
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
;;; External diagram runners (dot / plantuml) & request dispatch
;;; ---------------------------------------------------------------------------

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
                       (progn
                         (puthash key t etaf-org-typeset--running)
                         (let ((opts-json (if (eq kind 'math)
                                              (etaf-org-typeset--native-math-options-json env)
                                            (etaf-org-typeset--native-mermaid-options-json env))))
                           (etaf-doc-typeset-request
                            key kind source opts-json etaf-org-typeset--cache-directory
                            (lambda (_path)
                              (remhash key etaf-org-typeset--running)
                              (etaf-org-typeset--notify session))
                            (lambda (msg fatal)
                              (remhash key etaf-org-typeset--running)
                              (when fatal
                                (puthash key msg etaf-org-typeset--failed))))))
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
