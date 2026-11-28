;;; etaf-md-typeset.el --- Draw diagrams and formulas in the background -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Markdown adapter over `etaf-doc-typeset' for asynchronous Mermaid diagrams
;; and MathJax display formulas via the shared QuickJS native worker.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-ui)
(require 'etaf-doc)
(require 'etaf-md-cache)
(require 'etaf-md-model)
(require 'etaf-md-views)

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
  (expand-file-name "typeset/" etaf-md-cache--root-directory)
  "Directory holding one SVG per rendered block.")

(defconst etaf-md-typeset--scale 2
  "Pixels per point a picture is drawn at, so it stays sharp when it is placed.")

(defconst etaf-md-typeset--formula-scale 1.0
  "A display formula is set at the page's body size.")

(defconst etaf-md-typeset--picture-version 7
  "Version of the drawing a cache key stands for.")

(defconst etaf-md-typeset--max-rows 120
  "Upper row safety ceiling for typeset diagrams and display formulas.")

(defvar etaf-md-typeset--prefer-native t
  "When non-nil, use the embedded QuickJS native module when installed.")

(defvar etaf-md-typeset--running (make-hash-table :test #'equal)
  "Render in flight by block key, so one block never renders twice.")

(defvar etaf-md-typeset--failed (make-hash-table :test #'equal)
  "Renderer's message by block key of a block that cannot be drawn.")

(defvar etaf-md-typeset--native-hinted nil
  "Non-nil after hinting once per session about prebuilt native rendering.")

(defun etaf-md--typeset-pixels ()
  "Return the pixel size to typeset a formula at."
  (max 12 (round (* (etaf-md--base-pixels) etaf-md-typeset--formula-scale))))

(defun etaf-md-typeset--native-info ()
  "Return engine metadata plist when the native module is loaded, else nil."
  (when (and etaf-md-typeset etaf-md-typeset--prefer-native)
    (etaf-doc-typeset-info)))

(defun etaf-md-typeset-available-p ()
  "Return non-nil when this system can draw diagrams and formulas."
  (and etaf-md-typeset
       etaf-md-typeset--prefer-native
       (etaf-doc-typeset-available-p)))

;;; ---------------------------------------------------------------------------
;;; Colors, keys and cache lookup
;;; ---------------------------------------------------------------------------

(defun etaf-md--page-colors (env)
  "Return ENV's page colours, keyed by role, as #rrggbb."
  (let ((role (lambda (key) (etaf-md--hex-color (etaf-md--env-color env key)))))
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

(defun etaf-md--typeset-colors (env)
  "Return (PALETTE . INK) drawn for ENV's page."
  (let* ((background (or (plist-get env :background)
                         (etaf-md--env-color env :bg)))
         (dark (> (etaf-ui-color-contrast background "#ffffff")
                  (etaf-ui-color-contrast background "#000000"))))
    (cons (if dark 'dark 'light)
          (etaf-md--hex-color (etaf-md--env-color env :ink)))))

(defun etaf-md--native-mermaid-options-json (env)
  "Return the JSON options string passed to the native QuickJS Pele engine."
  (etaf-doc-typeset-options-json
   'mermaid (etaf-md--page-colors env)
   (list :font-size (max 10 (round (etaf-md--base-pixels)))
         :scale etaf-md-typeset--scale)))

(defun etaf-md--native-math-options-json (env)
  "Return the JSON options string passed to the native QuickJS MathJax engine."
  (etaf-doc-typeset-options-json
   'math (etaf-md--page-colors env)
   (list :pixels (etaf-md--typeset-pixels)
         :cell-height (cdr (etaf-md--cell-metrics))
         :scale etaf-md-typeset--scale)))

(defun etaf-md--typeset-page (env)
  "Return ENV's page constants for a picture key: (COLORS . CONFIG-HASH)."
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
                                     (etaf-md--native-math-options-json env))
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
  "Return BLOCK carrying the picture already rendered for it in ENV."
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

(defun etaf-md--typeset-figure (kind path env)
  "Return the View of the SVG picture at PATH for KIND in ENV."
  (let* ((width (max 24 (or (plist-get env :figure-width)
                            (plist-get env :width)
                            (when-let* ((session (plist-get env :session)))
                              (cdr (etaf-md--page-widths
                                    session (etaf-md--read session :width))))
                            92)))
         (pixels (when-let* ((natural (ignore-errors (etaf-doc-typeset-image-pixels path))))
                   (cons (/ (car natural) (float etaf-md-typeset--scale))
                         (/ (cdr natural) (float etaf-md-typeset--scale)))))
         (grid (or (etaf-doc-typeset-grid-for-pixels
                    pixels (- width 2) etaf-md-typeset--max-rows
                    (etaf-md--cell-metrics))
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
  "Start the renders SESSION's page needs and does not show yet."
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
                     (puthash key t etaf-md-typeset--running)
                     (let ((opts-json (if (eq kind 'math)
                                          (etaf-md--native-math-options-json env)
                                        (etaf-md--native-mermaid-options-json env))))
                       (etaf-doc-typeset-request
                        key kind source opts-json etaf-md-typeset--cache-directory
                        (lambda (_path)
                          (remhash key etaf-md-typeset--running)
                          (etaf-md--typeset-changed session))
                        (lambda (msg fatal)
                          (remhash key etaf-md-typeset--running)
                          (when fatal
                            (puthash key (or msg "the renderer gave no reason")
                                     etaf-md-typeset--failed))
                          (message "Preview kept a %s block's source: %s"
                                   (or kind 'drawing)
                                   (truncate-string-to-width (or msg "no reason given") 160))))))))))
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
