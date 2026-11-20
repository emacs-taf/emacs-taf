;;; etaf-org-preview-typeset.el --- Draw formulas and diagrams  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Org already carries these constructs as source: a display formula
;; (`$$...$$', `\[...\]' or a LaTeX environment) and a `mermaid' source block.
;; The parser and the renderer keep them as source, which is what a reader sees
;; when nothing else is installed.  When mermaid-cli is present this module
;; draws them: a diagram through `mmdc', a formula through the KaTeX and
;; Chromium that package already brings.
;;
;; A render is asynchronous and cached by what it depends on, so a repaint of
;; the same formula costs one file check.  Until the picture exists the block
;; keeps its source, and a finished render republishes the page in place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(require 'etaf-org-preview-model)
(require 'etaf-org-preview-views)

(declare-function image-size "image.c" (spec &optional pixels frame))
(declare-function etaf-ui-color-contrast "etaf-ui" (first second))

(defgroup etaf-org-preview-typeset nil
  "Formulas and diagrams drawn by an external program."
  :group 'etaf-org-preview)

(defcustom etaf-org-preview-typeset t
  "Whether the preview draws a formula and a mermaid block with a program.
When nil, or when mermaid-cli is not installed, both keep their source and the
plain-text rendering the shared renderer paints.  A page never waits for a
program either way: a picture that is not cached yet appears on the repaint
that follows its render."
  :type 'boolean)

(defconst etaf-org-preview-typeset--cache-directory
  (expand-file-name "etaf-org-preview/typeset/"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Directory holding one PNG per rendered block.")

(defconst etaf-org-preview-typeset--scale 2
  "Pixels per point a picture is drawn at, so it stays sharp when it is placed.")

(defconst etaf-org-preview-typeset--formula-scale 1.0
  "A display formula is set at the page's body size.")

(defvar etaf-org-preview-typeset--running (make-hash-table :test #'equal)
  "Render in flight by block key, so one block never renders twice.")

(defvar etaf-org-preview-typeset--failed (make-hash-table :test #'equal)
  "Sources KaTeX or mermaid-cli refused, so a page does not retry them.")

(defvar etaf-org-preview-typeset--missing nil
  "Non-nil once the programs were looked for and not found.")

(defun etaf-org-preview-typeset--script ()
  "Return the formula renderer's path, or nil when this checkout lacks it."
  (when-let* ((entry (locate-library "etaf-org-preview"))
              ((not (string-suffix-p ".eln" entry)))
              (script (expand-file-name "scripts/typeset-math.mjs"
                                        (file-name-directory entry)))
              ((file-exists-p script)))
    script))

(defun etaf-org-preview-typeset-available-p ()
  "Return non-nil when this system can draw formulas and diagrams.
Both need mermaid-cli: the diagram calls `mmdc', and the formula uses the
Chromium and KaTeX that package installs."
  (and etaf-org-preview-typeset
       (not etaf-org-preview-typeset--missing)
       (or (executable-find "mmdc")
           (setq etaf-org-preview-typeset--missing t))))

(defun etaf-org-preview-typeset--pixels ()
  "Return the pixel size a formula is typeset at."
  (max 12 (round (* (etaf-org-preview--base-pixels)
                    etaf-org-preview-typeset--formula-scale))))

(defun etaf-org-preview-typeset--dark-p (env)
  "Return non-nil when ENV's page is dark."
  (let ((background (plist-get env :background)))
    (if (and background (stringp background))
        (<= (etaf-ui-color-contrast background "#000000") 1.5)
      (eq (etaf-appearance) 'dark))))

(defun etaf-org-preview-typeset--color (env key)
  "Return ENV's colour for KEY, falling back to a fixed palette.
A headless frame has no face colours, so an `auto' page would otherwise hand a
program the string `unspecified-bg' and mermaid would reject the drawing."
  (let ((value (etaf-org-preview--color env key)))
    (if (and (stringp value)
             (string-match-p "\\`#[0-9a-fA-F]\\{3,8\\}\\'" value))
        value
      (etaf-org-preview-color
       key
       (cdr (assq (if (etaf-org-preview-typeset--dark-p env) 'dark 'light)
                  etaf-org-preview-themes))))))

(defun etaf-org-preview-typeset--colors (env)
  "Return (PALETTE . INK) drawn for ENV's page."
  (cons (if (etaf-org-preview-typeset--dark-p env) 'dark 'light)
        (etaf-org-preview-typeset--color env :ink)))

(defconst etaf-org-preview-mermaid-fonts
  '("LXGW WenKai" "LXGW WenKai Mono" "PingFang SC" "Hiragino Sans GB"
    "Helvetica Neue" "Arial" "sans-serif")
  "Families a diagram falls back to when the reader's own font lacks a glyph.
The WenKai faces carry the CJK shapes a diagram label needs; the rest are
families every desktop has, so a label is always measurable.")

(defun etaf-org-preview-typeset--mermaid-font-family ()
  "Return the font stack a diagram is drawn and measured with.
The reader's default face comes first, so a diagram uses the type they read
the page in; the names after it cover the glyphs that face may lack."
  (let* ((family (ignore-errors (face-attribute 'default :family nil t)))
         (names (if (and (stringp family)
                         (not (string-empty-p family))
                         (not (string= family "default")))
                    (cons family etaf-org-preview-mermaid-fonts)
                  etaf-org-preview-mermaid-fonts)))
    (mapconcat #'identity (delete-dups names) ", ")))

(defun etaf-org-preview-typeset--mermaid-config (env)
  "Return the mermaid configuration JSON drawn for ENV's page.
The diagram is built from the page's own colours instead of mermaid's fixed
`default' and `dark' palettes, so a light page carries light boxes with its own
ink.  Every diagram kind gets the page's own font and size, because a sequence
diagram otherwise draws its messages at 12px beside 14px actors and a flowchart
at another size again."
  (let ((ink (etaf-org-preview-typeset--color env :ink))
        (panel (etaf-org-preview-typeset--color env :panel))
        (panel2 (etaf-org-preview-typeset--color env :panel2))
        (border (etaf-org-preview-typeset--color env :border))
        (muted (etaf-org-preview-typeset--color env :muted))
        (quote (etaf-org-preview-typeset--color env :quote-bg))
        (page (or (plist-get env :background)
                  (etaf-org-preview-typeset--color env :bg)))
        (base (round (etaf-org-preview--base-pixels))))
    (json-encode
     `((look . "classic")
       (theme . "base")
       (themeVariables
        . ((background . "transparent")
           (primaryColor . ,panel)
           (primaryTextColor . ,ink)
           (primaryBorderColor . ,border)
           (secondaryColor . ,panel2)
           (secondaryTextColor . ,ink)
           (tertiaryColor . ,quote)
           (tertiaryTextColor . ,ink)
           (lineColor . ,muted)
           (textColor . ,ink)
           (mainBkg . ,panel)
           (nodeBorder . ,border)
           (clusterBkg . ,quote)
           (clusterBorder . ,border)
           (edgeLabelBackground . ,page)
           (actorBkg . ,panel)
           (actorBorder . ,border)
           (actorTextColor . ,ink)
           (signalColor . ,muted)
           (signalTextColor . ,ink)
           (labelBoxBkgColor . ,panel)
           (labelBoxBorderColor . ,border)
           (labelTextColor . ,ink)
           (noteBkgColor . ,quote)
           (noteTextColor . ,ink)
           (noteBorderColor . ,border)
           (fontFamily . ,(etaf-org-preview-typeset--mermaid-font-family))
           (fontSize . ,(format "%dpx" base))))
       (flowchart . ((padding . 12) (useMaxWidth . t) (htmlLabels . t)))
       (sequence . ((diagramMarginX . 16) (diagramMarginY . 12)
                    (actorMargin . 40) (boxMargin . 10)
                    (actorFontSize . ,base) (messageFontSize . ,base)
                    (noteFontSize . ,base)))
       (gantt . ((fontSize . ,base) (sectionFontSize . ,base)))
       (er . ((fontSize . ,base)))
       (requirement . ((fontSize . ,base)))
       (state . ((fontSize . ,base)))))))

(defun etaf-org-preview-typeset--key (kind source env)
  "Return the cache key of KIND drawn from SOURCE for ENV's surface.
The key holds what the picture depends on, so a theme, font, cell-height or
mermaid-configuration change draws a new file instead of reusing the old one."
  (let ((colors (etaf-org-preview-typeset--colors env)))
    (secure-hash
     'sha1
     (format "%s\n%s\n%s\n%s\n%s"
             kind source
             (car colors) (cdr colors)
             (if (eq kind 'math)
                 (format "%d/%d"
                         (etaf-org-preview-typeset--pixels)
                         (max 1 (or (ignore-errors (frame-char-height)) 16)))
               (secure-hash 'sha1
                            (etaf-org-preview-typeset--mermaid-config env)))))))

(defun etaf-org-preview-typeset--path (key)
  "Return the PNG path of KEY."
  (expand-file-name (concat key ".png") etaf-org-preview-typeset--cache-directory))

(defun etaf-org-preview-typeset--kind (block)
  "Return how BLOCK is drawn, or nil when it keeps its source.
A display formula and a LaTeX environment are math; a `mermaid' source block is
the diagram language Org users already write as a source block."
  (pcase (plist-get block :type)
    ('display-math 'math)
    ('latex-environment 'math)
    ('src-block (and (equal (downcase (or (plist-get block :lang) "")) "mermaid")
                     'mermaid))))

(defun etaf-org-preview-typeset--source (block)
  "Return the math source of BLOCK that the typesetter can draw.
An Org LaTeX environment carries its own `\\\\begin{...}' and `\\\\end{...}'.
KaTeX knows `aligned' but not `equation', and feeding it the wrapper made it
draw the wrapper as text on top of the formula.  A display-only environment is
therefore unwrapped, and an `align' environment becomes the `aligned' form
KaTeX does understand; an environment it already knows stays whole."
  (let ((text (or (plist-get block :text) "")))
    (if (not (eq (plist-get block :type) 'latex-environment))
        text
      (if (string-match
           "\\`[ \t]*\\\\begin{\\([^}]+\\)}\\(\\(?:.\\|\n\\)*\\)\\\\end{\\1}[ \t]*\\'"
           text)
          (let ((environment (match-string 1 text))
                (body (match-string 2 text)))
            (pcase environment
              ((or "equation" "equation*" "displaymath" "math")
               body)
              ((or "align" "align*" "flalign" "flalign*"
                   "gather" "gather*" "multline" "multline*")
               (format "\\begin{aligned}%s\\end{aligned}" body))
              (_ text)))
        text))))

(defun etaf-org-preview-typeset-attach (block env)
  "Return BLOCK carrying the picture already rendered for it in ENV.
The block gains `:picture', the PNG path, when one exists; the renderer draws
that and leaves a block without one as its source."
  (if-let* ((kind (etaf-org-preview-typeset--kind block))
            (source (etaf-org-preview-typeset--source block))
            ((not (string-blank-p source)))
            ((etaf-org-preview-typeset-available-p))
            (key (etaf-org-preview-typeset--key kind source env))
            ((not (gethash key etaf-org-preview-typeset--failed)))
            (path (etaf-org-preview-typeset--path key))
            ((file-exists-p path)))
      (plist-put (copy-sequence block) :picture path)
    block))

(defun etaf-org-preview-typeset--figure (kind path env)
  "Return the View of the picture at PATH for KIND in ENV.
The picture fills the reading measure instead of the frame: a diagram keeps
its own aspect ratio and a formula is a line of the text around it."
  (let* ((width (max 24 (or (plist-get env :width) 92)))
         (natural (ignore-errors (image-size (create-image path) t)))
         (pixels (when natural
                   (cons (/ (car natural) (float etaf-org-preview-typeset--scale))
                         (/ (cdr natural) (float etaf-org-preview-typeset--scale)))))
         (grid (etaf-org-preview--media-grid-for-pixels pixels (max 8 (- width 2))))
         (image (etaf-node 'image
                           (list :src path
                                 :columns (car grid)
                                 :rows (cdr grid)
                                 :adapter 'auto)
                           nil))
         (caption (format "%s（按 RET 打开）"
                          (file-name-nondirectory path))))
    (if (eq kind 'math)
        (etaf-node 'column
                   (list :width (list 'ch width) :cross-align 'center)
                   (list image))
      (etaf-node 'column
                 (list :width (list 'ch width) :cross-align 'center
                       :item-gap '(lh 0)
                       :on-press (lambda ()
                                   (etaf-org-preview--act env :open-file path))
                       :role 'button :tab-index 0 :pointer 'hand
                       :help-echo caption)
                 (list image
                       (etaf-node 'text
                                  (list :color (etaf-org-preview-typeset--color env :muted)
                                        :font-size (etaf-org-preview--scaled 0.85))
                                  (list "▲ mermaid")))))))

(defun etaf-org-preview--typeset-figure (kind path env)
  "Draw the picture at PATH as KIND in ENV."
  (etaf-org-preview-typeset--figure kind path env))

(defun etaf-org-preview-typeset--start (key kind source env done)
  "Start rendering SOURCE of KIND for KEY, and return the process."
  (let ((directory etaf-org-preview-typeset--cache-directory)
        (path (etaf-org-preview-typeset--path key))
        (colors (etaf-org-preview-typeset--colors env))
        (inhibit-message t))
    (make-directory directory t)
    (condition-case error
        (let* ((input (expand-file-name
                       (concat key (if (eq kind 'math) ".tex" ".mmd")) directory))
               (arguments
                (progn
                  (with-temp-file input (insert source))
                  (pcase kind
                    ('math
                     (let ((script (etaf-org-preview-typeset--script)))
                       (unless script (error "No formula renderer in this checkout"))
                       (list "node" script input path (cdr colors)
                             (number-to-string (etaf-org-preview-typeset--pixels))
                             (number-to-string
                              (max 1 (or (ignore-errors (frame-char-height)) 16))))))
                    (_
                     (let ((config (expand-file-name (concat key ".json") directory)))
                       (with-temp-file config
                         (insert (etaf-org-preview-typeset--mermaid-config env)))
                       (list "mmdc" "-i" input "-o" path "-c" config
                             "-b" "transparent"
                             "-s" (number-to-string etaf-org-preview-typeset--scale)
                             "-q"))))))
               (process (make-process
                         :name (format "etaf-org-preview-%s" kind)
                         :command arguments
                         :connection-type 'pipe
                         :noquery t
                         :filter #'ignore
                         :sentinel
                         (lambda (process _event)
                           (when (memq (process-status process) '(exit signal))
                             (remhash key etaf-org-preview-typeset--running)
                             (if (and (eq (process-status process) 'exit)
                                      (zerop (process-exit-status process))
                                      (file-exists-p path))
                                 (run-at-time 0 nil done)
                               (puthash key t etaf-org-preview-typeset--failed)))))))
          (puthash key process etaf-org-preview-typeset--running)
          (ignore input)
          process)
      (error
       (message "Org preview kept the source of a %s block: %s"
                kind (error-message-string error))
       nil))))

(defun etaf-org-preview-typeset--walk-blocks (entries function)
  "Call FUNCTION on every block carried by ENTRIES, children included."
  (dolist (entry entries)
    (when-let* ((block (plist-get entry :block)))
      (funcall function block))
    (when-let* ((body (plist-get entry :body)))
      (etaf-org-preview-typeset--walk-blocks body function))
    (when-let* ((children (plist-get entry :children)))
      (etaf-org-preview-typeset--walk-blocks children function))))

(defun etaf-org-preview-typeset-request (session)
  "Start the renders SESSION's page needs and does not show yet."
  (when (etaf-org-preview-typeset-available-p)
    (let ((document (etaf-org-preview--read session :document))
          (env (etaf-org-preview--env session))
          (wanted nil))
      (etaf-org-preview-typeset--walk-blocks
       (append (plist-get document :preamble-entries)
               (plist-get document :section-entries))
       (lambda (block)
         (when-let* ((kind (etaf-org-preview-typeset--kind block))
                     (source (etaf-org-preview-typeset--source block))
                     ((not (string-blank-p source)))
                     (key (etaf-org-preview-typeset--key kind source env))
                     ((not (gethash key etaf-org-preview-typeset--failed)))
                     ((not (file-exists-p (etaf-org-preview-typeset--path key))))
                     ((not (gethash key etaf-org-preview-typeset--running))))
           (push (list kind source key) wanted))))
      (when wanted
        (run-at-time 0 nil
                     (lambda ()
                       (dolist (item (nreverse wanted))
                         (unless (or (file-exists-p
                                      (etaf-org-preview-typeset--path (nth 2 item)))
                                     (gethash (nth 2 item) etaf-org-preview-typeset--running))
                           (etaf-org-preview-typeset--start
                            (nth 2 item) (nth 0 item) (nth 1 item) env
                            (lambda () (etaf-org-preview-typeset--changed session)))))))))))

(defun etaf-org-preview-typeset--changed (session)
  "Repaint SESSION once, however many pictures arrive together."
  (unless (plist-get session :typeset-pending)
    (plist-put session :typeset-pending t)
    (run-at-time 0 nil
                 (lambda ()
                   (plist-put session :typeset-pending nil)
                   (when (or (plist-get session :buffer)
                             (plist-get session :file)
                             (plist-get session :text))
                     (etaf-org-preview--install
                      session (etaf-org-preview--current-text session)))))))

(provide 'etaf-org-preview-typeset)
;;; etaf-org-preview-typeset.el ends here
