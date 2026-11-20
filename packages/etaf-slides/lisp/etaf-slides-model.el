;;; etaf-slides-model.el --- Deck model for etaf-slides -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The deck model: a markdown source becomes a list of slides, a session keeps
;; the reactive cells a render reads, and the stage geometry turns a window's
;; pixel size into the 16:9 character grid a slide is laid out in.
;;
;; Everything here is pure Elisp over data.  No buffer, no timer and no file
;; access outside `etaf-slides-create', so the whole module is testable in a
;; batch Emacs and a view never reaches the filesystem through it.
;;
;; Deck format: an optional YAML front matter (title, theme, author, date), then
;; slides separated by a line of three or more dashes.  Inside a slide, the
;; first heading is its title and a `::: notes' block holds the speaker notes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-slides-theme)

(define-error 'etaf-slides-error "ETAF slides error")

(defconst etaf-slides-aspect-width 16
  "Width of the stage aspect ratio.")

(defconst etaf-slides-aspect-height 9
  "Height of the stage aspect ratio.")

(defconst etaf-slides-minimum-columns 32
  "Narrowest stage this application lays out before clipping.")

(defconst etaf-slides-minimum-rows 10
  "Shortest stage this application lays out before clipping.")

(defconst etaf-slides--chrome-rows 2
  "Rows the shell spends outside the stage: one gap and one footer line.")

(defconst etaf-slides--inset-rows 4
  "Rows the stage spends on its own padding, title band and gap.")

;;; Deck reading

(defun etaf-slides--separator-p (line)
  "Return non-nil when LINE separates two slides."
  (string-match-p "\\`---[-]*[ \t]*\\'" line))

(defun etaf-slides--blank-p (lines)
  "Return non-nil when every line of LINES is blank."
  (cl-every (lambda (line) (string-empty-p (string-trim line))) lines))

(defun etaf-slides--parse-meta (text)
  "Return the front matter of TEXT as a plist.
Keys are lower-case symbols; values are trimmed strings."
  (let (plist)
    (dolist (line (split-string text "\n"))
      (when (string-match "\\`\\([A-Za-z][A-Za-z0-9_-]*\\):[ \t]*\\(.*\\)\\'" line)
        (let ((key (intern (concat ":" (downcase (match-string 1 line)))))
              (value (string-trim (match-string 2 line))))
          (setq plist (plist-put plist key value)))))
    plist))

(defun etaf-slides--extract-notes (text)
  "Return (BODY . NOTES) for slide TEXT.
A `::: notes' line opens a notes block that the closing `:::' line ends; the
block leaves the visible body and becomes the speaker notes."
  (let (body notes (in-notes nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((and (not in-notes) (string-match-p "\\`:::[ \t]*notes[ \t]*\\'" line))
        (setq in-notes t))
       ((and in-notes (string-match-p "\\`:::[ \t]*\\'" line))
        (setq in-notes nil))
       (in-notes (push line notes))
       (t (push line body))))
    (cons (string-trim (mapconcat #'identity (nreverse body) "\n"))
          (string-trim (mapconcat #'identity (nreverse notes) "\n")))))

(defun etaf-slides--inline-text (nodes)
  "Return the plain text of inline NODES."
  (mapconcat
   (lambda (node)
     (pcase (plist-get node :type)
       ((or 'text 'code 'html) (or (plist-get node :text) ""))
       ((or 'emph 'strong 'strike 'link)
        (etaf-slides--inline-text (plist-get node :children)))
       ('image (or (plist-get node :alt) ""))
       ('autolink (or (plist-get node :text) ""))
       ('break " ")
       (_ "")))
   nodes ""))

(defun etaf-slides--blocks-text (blocks)
  "Return the plain text of BLOCKS, one block per line."
  (mapconcat
   (lambda (block)
     (etaf-slides--inline-text (plist-get block :children)))
   (seq-filter (lambda (block) (plist-get block :children)) blocks)
   " "))

(defun etaf-slides--layout (heading blocks)
  "Return the layout of a slide with HEADING and BODY BLOCKS.
A slide whose only content is its heading is a section divider; a heading with
at most two paragraphs and nothing else is a cover; everything else is
content and reads top to bottom under its title."
  (cond
   ((null heading) 'content)
   ((null blocks) 'section)
   ((and (<= (length blocks) 2)
         (cl-every (lambda (block) (eq (plist-get block :type) 'paragraph)) blocks))
    'cover)
   (t 'content)))

(defun etaf-slides--slide (index text)
  "Return the slide plist for the INDEX-th slide source TEXT."
  (let* ((split (etaf-slides--extract-notes text))
         (document (etaf-ui-markdown-parse (car split) 'gfm))
         (blocks (plist-get document :children))
         (heading (seq-find (lambda (block)
                              (eq (plist-get block :type) 'heading))
                            blocks))
         (title (or (and heading (etaf-slides--inline-text (plist-get heading :children)))
                    (format "第 %d 页" (1+ index))))
         (body (if heading (delq heading (copy-sequence blocks)) blocks)))
    (list :index index
          :title (string-trim title)
          :layout (etaf-slides--layout heading body)
          :blocks body
          :notes (cdr split)
          :notes-p (not (string-empty-p (cdr split))))))

(defun etaf-slides--split-slides (text)
  "Return the slide sources of TEXT, dropping empty ones."
  (let (chunks (current nil))
    (dolist (line (split-string text "\n"))
      (if (etaf-slides--separator-p line)
          (unless (etaf-slides--blank-p current)
            (push (string-trim (mapconcat #'identity (nreverse current) "\n")) chunks)
            (setq current nil))
        (push line current)))
    (unless (etaf-slides--blank-p current)
      (push (string-trim (mapconcat #'identity (nreverse current) "\n")) chunks))
    (nreverse chunks)))

(defun etaf-slides--parse (text)
  "Return (META . SLIDES) for the deck source TEXT."
  (let ((body text)
        (meta nil))
    (when (string-match "\\`---[ \t]*\r?\n" body)
      ;; Capture the closing offset before anything else moves the match data:
      ;; the front matter reader matches per line.
      (let* ((start (match-end 0))
             (close (string-match "^---[ \t]*\r?$" body start))
             (close-end (and close (match-end 0))))
        (when close
          (setq meta (etaf-slides--parse-meta (substring body start close))
                body (string-trim-left (substring body close-end))))))
    (cons meta
          (cl-loop for text in (etaf-slides--split-slides body)
                   for index from 0
                   collect (etaf-slides--slide index text)))))

;;; Stage geometry

(defun etaf-slides-stage (width rows &optional char-width line-height)
  "Return the stage geometry for a WIDTH-pixel, ROWS-line viewport.
CHAR-WIDTH and LINE-HEIGHT are the frame's cell metrics in pixels.  The stage
keeps the 16:9 aspect ratio: it takes the full width when the window is wide
enough, otherwise it takes the full height and narrows, and it never exceeds
either budget.  The result is a plist with `:columns', `:rows' (the stage
itself), `:body-rows' (room for slide content) and `:clipped' (the viewport is
smaller than the application's minimum usable stage)."
  (let* ((char-width (max 1 (or char-width 8)))
         (line-height (max 1 (or line-height 17)))
         (aspect (/ (float etaf-slides-aspect-width) etaf-slides-aspect-height))
         ;; One cell is taller than wide, so a row carries more columns than
         ;; the ratio alone suggests.
         (columns-per-row (/ (* aspect line-height) char-width))
         (available-rows (max 1 (- rows etaf-slides--chrome-rows)))
         (available-columns (max 1 (floor width char-width)))
         (columns-by-rows (max 8 (round (* available-rows columns-per-row))))
         (columns (min available-columns columns-by-rows))
         (stage-rows (max 3 (round (/ columns columns-per-row))))
         (clipped (or (< columns etaf-slides-minimum-columns)
                      (< stage-rows etaf-slides-minimum-rows))))
    (setq columns (max etaf-slides-minimum-columns columns)
          stage-rows (max etaf-slides-minimum-rows stage-rows))
    (list :columns columns
          :rows stage-rows
          :body-rows (max 1 (- stage-rows etaf-slides--inset-rows))
          :clipped clipped)))

;;; Line estimate

(defun etaf-slides-display-width (string)
  "Return the display width of STRING in character cells.
A wide character counts two columns, a tab counts four; the estimate only
feeds the overflow warning, so it stays independent of the frame's font."
  (let ((width 0))
    (dolist (char (string-to-list string) width)
      (setq width (+ width (pcase char
                             (?\t 4)
                             (_ (if (>= (char-width char) 2) 2 1))))))))

(defun etaf-slides--wrapped-lines (text columns)
  "Return how many COLUMNS-wide lines TEXT occupies."
  (max 1 (ceiling (/ (float (max 1 (etaf-slides-display-width text)))
                     (max 1 columns)))))

(defun etaf-slides--block-lines (block columns)
  "Return the estimated rows BLOCK occupies in COLUMNS."
  (pcase (plist-get block :type)
    ('heading 1)
    ('paragraph (etaf-slides--wrapped-lines
                 (etaf-slides--inline-text (plist-get block :children)) columns))
    ('code-block (length (split-string (or (plist-get block :text) "") "\n")))
    ('blockquote (1+ (etaf-slides--blocks-lines
                      (plist-get block :children) (max 1 (- columns 2)))))
    ('list (cl-loop for item in (plist-get block :items)
                    sum (etaf-slides--blocks-lines
                         (plist-get item :children) (max 1 (- columns 2)))))
    ('table (1+ (length (plist-get block :rows))))
    ('thematic-break 1)
    ('html-block 1)
    ('footnote-def 0)
    (_ 1)))

(defun etaf-slides--blocks-lines (blocks columns)
  "Return the estimated rows BLOCKS occupy in COLUMNS.
Consecutive blocks are separated by one blank line, as the renderer does."
  (if (null blocks)
      0
    (let ((lines 0) (count 0))
      (dolist (block blocks)
        (setq lines (+ lines (etaf-slides--block-lines block columns))
              count (1+ count)))
      (+ lines (1- count)))))

(defun etaf-slides-lines (slide columns)
  "Return the estimated rows SLIDE occupies in COLUMNS.
The title band costs two rows, one for the title and one for the gap under it."
  (if (eq (plist-get slide :layout) 'content)
      (+ 2 (etaf-slides--blocks-lines (plist-get slide :blocks) columns))
    1))

;;; Session

(defun etaf-slides--ref (session key)
  "Return SESSION's reactive cell for KEY."
  (plist-get session key))

(defun etaf-slides--read (session key)
  "Return SESSION's current value for KEY."
  (etaf-value (plist-get session key)))

(defun etaf-slides--write (session key value)
  "Store VALUE in SESSION's cell KEY."
  (setf (etaf-value (plist-get session key)) value)
  value)

(cl-defun etaf-slides-create (&key file text title theme)
  "Return a new headless slide session.
FILE is a markdown deck read from disk, or TEXT is the deck itself; one of
them is required.  TITLE overrides the deck title and THEME starts at
`light', `dark' or `auto' (the default).  A missing or unreadable FILE
signals `etaf-slides-error'."
  (when (and file text)
    (signal 'etaf-slides-error '("Give either :file or :text, not both")))
  (let* ((source (cond (text text)
                       (file (unless (file-readable-p file)
                               (signal 'etaf-slides-error
                                       (list (format "Cannot read deck: %s" file))))
                             (with-temp-buffer
                               (set-buffer-multibyte t)
                               (insert-file-contents file)
                               (buffer-string)))
                       (t "")))
         (parsed (etaf-slides--parse source))
         (meta (car parsed))
         (slides (cdr parsed)))
    (unless slides
      (signal 'etaf-slides-error '("The deck has no slides")))
    (list :file file
          :source source
          :meta meta
          :slides slides
          :title (or title (plist-get meta :title) "未命名幻灯片")
          :index (etaf-ref 0)
          :theme (etaf-ref (or theme 'auto))
          :mode (etaf-ref 'stage)
          :notes (etaf-ref nil)
          :clock (etaf-ref nil)
          :viewport (etaf-ref (cons 1200 40)))))

(defun etaf-slides-slides (session)
  "Return SESSION's slide plists in deck order."
  (plist-get session :slides))

(defun etaf-slides-current (session)
  "Return SESSION's current slide plist."
  (nth (etaf-slides--read session :index) (plist-get session :slides)))

(defun etaf-slides-state (session)
  "Return SESSION as plain data.
The plist carries `:title', `:file', `:index' (zero based), `:count',
`:layout', `:mode', `:theme' (the resolved appearance), `:notes-visible',
`:clock' and `:overflow', the zero-based indices whose estimated content does
not fit the current stage."
  (let* ((stage (etaf-slides--read session :viewport))
         (metrics (ignore-errors (etaf-display-metrics)))
         (geometry (etaf-slides-stage (car stage) (cdr stage)
                                      (plist-get metrics :char-width)
                                      (plist-get metrics :line-height)))
         (slide (etaf-slides-current session))
         (slides (plist-get session :slides))
         (theme (etaf-slides--read session :theme))
         (clock (etaf-slides--read session :clock)))
    (list :title (plist-get session :title)
          :file (plist-get session :file)
          :index (etaf-slides--read session :index)
          :count (length slides)
          :title-of (plist-get slide :title)
          :layout (plist-get slide :layout)
          :notes (plist-get slide :notes)
          :notes-visible (and (etaf-slides--read session :notes) t)
          :mode (etaf-slides--read session :mode)
          :theme theme
          :appearance (etaf-slides-resolve-theme theme)
          :clock clock
          :stage geometry
          :overflow (cl-loop for each in slides
                             for index from 0
                             when (> (etaf-slides-lines each (plist-get geometry :columns))
                                     (plist-get geometry :body-rows))
                             collect index))))

(defun etaf-slides-goto (session index)
  "Show slide INDEX of SESSION, clamped to the deck, and return it."
  (let ((count (length (plist-get session :slides))))
    (etaf-slides--write session :index
                        (max 0 (min (1- count) (or index 0))))))

(defun etaf-slides-show (session index)
  "Show slide INDEX of SESSION on the stage and return the index.
Leaving the overview for a chosen slide is one action, so a caller does not
have to pair a jump with a mode change."
  (etaf-slides-goto session index)
  (etaf-slides-set-mode session 'stage)
  (etaf-slides--read session :index))

(defun etaf-slides-next (session &optional count)
  "Move SESSION forward by COUNT slides (one by default) and return the index."
  (etaf-slides-goto session (+ (etaf-slides--read session :index) (or count 1))))

(defun etaf-slides-previous (session &optional count)
  "Move SESSION back by COUNT slides (one by default) and return the index."
  (etaf-slides-next session (- (or count 1))))

(defun etaf-slides-set-mode (session mode)
  "Set SESSION's mode to `stage' or `overview' and return it."
  (unless (memq mode '(stage overview))
    (signal 'etaf-slides-error (list (format "Unknown mode: %S" mode))))
  (etaf-slides--write session :mode mode))

(defun etaf-slides-set-theme (session theme)
  "Set SESSION's THEME to `light', `dark' or `auto' and return it."
  (unless (memq theme '(light dark auto))
    (signal 'etaf-slides-error (list (format "Unknown theme: %S" theme))))
  (etaf-slides--write session :theme theme))

(defun etaf-slides-cycle-theme (session)
  "Advance SESSION's theme light, then dark, then auto; return the new theme."
  (etaf-slides-set-theme
   session
   (pcase (etaf-slides--read session :theme)
     ('light 'dark)
     ('dark 'auto)
     (_ 'light))))

(defun etaf-slides-set-notes (session flag)
  "Show SESSION's speaker notes when FLAG is non-nil; return FLAG."
  (etaf-slides--write session :notes (and flag t)))

(defun etaf-slides-set-clock (session seconds)
  "Set SESSION's elapsed presentation clock to SECONDS."
  (etaf-slides--write session :clock seconds))

(provide 'etaf-slides-model)
;;; etaf-slides-model.el ends here
