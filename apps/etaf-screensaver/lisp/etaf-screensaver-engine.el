;;; etaf-screensaver-engine.el --- Playlist, framing and retained publication -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Compiles user playback settings before window takeover, advances one scene
;; session on a reusable scratch canvas, optionally adds a quiet card frame,
;; blends page changes with a top-to-bottom row reveal and publishes only
;; changed rows through ETAF's retained Text Host boundary.

;;; Code:
(require 'cl-lib)
(require 'etaf)
(require 'etaf-screensaver-canvas)
(require 'etaf-screensaver-scene)

(defgroup etaf-screensaver nil
  "Generative, input-dismissed screensavers."
  :group 'multimedia)

(defcustom etaf-screensaver-playlist
  '(matrix snow donut plasma equalizer sand poems clock)
  "Screensaver playlist repeated until input dismisses presentation.
Accepts a single scene symbol (e.g. `snow'), a single configured scene item
`(matrix :speed 12 :duration 20)', or a list mixing both forms.  Each item
accepts `:duration', `:frame-rate', `:background', `:frame', `:params' and
any keyword naming one of the scene's own parameters."
  :type 'sexp
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-order 'sequential
  "How `etaf-screensaver-playlist' chooses scenes in each round.
`sequential' preserves list order, `shuffle' visits every item once per
round in random order, and `random' samples with replacement."
  :type '(choice (const :tag "Sequential" sequential)
                 (const :tag "Shuffle" shuffle)
                 (const :tag "Random" random))
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-duration 30
  "Default seconds spent on each scene when neither item nor scene sets one."
  :type 'number
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-frame-rate 30
  "Maximum frames per second in (0, 60]; caps every scene's requested rate."
  :type 'number
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-background "#05070B"
  "Default canvas background color when a scene does not specify its own."
  :type 'color
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-frame nil
  "Global canvas framing override: nil uses each scene's own `:frame'.
`full' fills the window; `card' insets a thin border with an even mat and
lower-left title and summary.  An explicit item `:frame' still wins."
  :type '(choice (const :tag "Scene default" nil)
                 (const :tag "Full window" full)
                 (const :tag "Gallery card" card))
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-transition-duration 1.0
  "Seconds for a top-to-bottom reveal between different pages (0 to 5).
Zero disables transitions.  Capped at half of the incoming page's duration."
  :type 'number
  :group 'etaf-screensaver)

;;; Playlist validation and compilation.

(defconst etaf-screensaver--item-option-keys
  '(:duration :frame-rate :background :frame :params)
  "Reserved item-level keys in a playlist entry.")

(defun etaf-screensaver--validate-options ()
  "Validate global playback options before modifying any windows."
  (unless (memq etaf-screensaver-order '(sequential shuffle random))
    (etaf-screensaver--fail "Order must be sequential, shuffle or random"))
  (unless (and (numberp etaf-screensaver-duration)
               (> etaf-screensaver-duration 0)
               (<= etaf-screensaver-duration 86400))
    (etaf-screensaver--fail "Duration must be positive and at most one day"))
  (unless (and (numberp etaf-screensaver-frame-rate)
               (> etaf-screensaver-frame-rate 0)
               (<= etaf-screensaver-frame-rate 60))
    (etaf-screensaver--fail "Frame rate must be in (0, 60]"))
  (unless (stringp etaf-screensaver-background)
    (etaf-screensaver--fail "Background must be a color string"))
  (unless (or (null etaf-screensaver-frame)
              (memq etaf-screensaver-frame etaf-screensaver--frame-styles))
    (etaf-screensaver--fail "Frame style must be nil, full or card"))
  (unless (and (numberp etaf-screensaver-transition-duration)
               (<= 0 etaf-screensaver-transition-duration 5))
    (etaf-screensaver--fail "Transition duration must be between 0 and 5 seconds")))

(defun etaf-screensaver--merge-params (scene overrides)
  "Merge OVERRIDES alist onto SCENE's declared default params."
  (unless (proper-list-p overrides)
    (etaf-screensaver--fail "Scene parameters must be an alist"))
  (let ((defaults (etaf-screensaver--scene-params scene))
        (seen nil)
        (values nil))
    (dolist (entry overrides)
      (unless (and (consp entry) (symbolp (car entry)))
        (etaf-screensaver--fail "Invalid parameter entry: %S" entry))
      (let ((key (etaf-screensaver--param-key (car entry))))
        (unless (assq key defaults)
          (etaf-screensaver--fail "Unknown parameter %s for scene %s"
                                  key (etaf-screensaver--scene-id scene)))
        (unless (memq key seen)
          (push key seen)
          (push (cons key (cdr entry)) values))))
    (dolist (entry defaults)
      (unless (assq (car entry) values)
        (push (cons (car entry) (cdr entry)) values)))
    (nreverse values)))

(defun etaf-screensaver--compile-item (entry)
  "Compile one playlist ENTRY into a validated item plist."
  (let* ((configured (and (consp entry) (symbolp (car entry))))
         (id (cond ((symbolp entry) entry)
                   (configured (car entry))
                   (t (etaf-screensaver--fail
                       "Playlist item must be a scene symbol or (SCENE :key val ...): %S"
                       entry))))
         (scene (etaf-screensaver--scene id))
         (plist (and configured (cdr entry)))
         (seen nil)
         (inline-params nil))
    (when plist
      (unless (and (proper-list-p plist) (zerop (% (length plist) 2)))
        (etaf-screensaver--fail "Playlist item %s options must be key/value pairs" id))
      (let ((tail plist))
        (while tail
          (let ((key (pop tail))
                (val (pop tail)))
            (unless (keywordp key)
              (etaf-screensaver--fail "Playlist item %s option key must be a keyword: %S" id key))
            (when (memq key seen)
              (etaf-screensaver--fail "Playlist item %s repeats option %S" id key))
            (push key seen)
            (unless (memq key etaf-screensaver--item-option-keys)
              (push (cons key val) inline-params))))))
    (let ((duration (or (plist-get plist :duration)
                        (etaf-screensaver--scene-duration scene)
                        etaf-screensaver-duration))
          (rate (or (plist-get plist :frame-rate)
                    (etaf-screensaver--scene-frame-rate scene)))
          (background (or (plist-get plist :background)
                          (etaf-screensaver--scene-background scene)
                          etaf-screensaver-background))
          (frame (or (plist-get plist :frame)
                     etaf-screensaver-frame
                     (etaf-screensaver--scene-frame scene)
                     'full))
          (params (etaf-screensaver--merge-params
                   scene (append (nreverse inline-params)
                                 (plist-get plist :params)))))
      (unless (and (numberp duration) (> duration 0) (<= duration 86400))
        (etaf-screensaver--fail "Scene %s duration must be in (0, 86400]" id))
      (unless (and (numberp rate) (> rate 0) (<= rate 60))
        (etaf-screensaver--fail "Scene %s frame rate must be in (0, 60]" id))
      (unless (stringp background)
        (etaf-screensaver--fail "Scene %s background must be a color string" id))
      (unless (memq frame etaf-screensaver--frame-styles)
        (etaf-screensaver--fail "Scene %s frame must be full or card" id))
      (list :scene id
            :definition scene
            :duration duration
            :frame-rate (min rate etaf-screensaver-frame-rate)
            :background background
            :frame frame
            :params params))))

(defun etaf-screensaver--compile-playlist (playlist)
  "Validate and compile PLAYLIST into a nonempty list of item plists."
  (let ((entries
         (cond
          ((null playlist)
           (etaf-screensaver--fail "Playlist must not be empty"))
          ((symbolp playlist) (list playlist))
          ((and (proper-list-p playlist) (symbolp (car playlist))
                (keywordp (cadr playlist)))
           (list playlist))
          ((proper-list-p playlist) playlist)
          (t (etaf-screensaver--fail "Playlist must be a scene symbol or list")))))
    (when (> (length entries) 1000)
      (etaf-screensaver--fail "Playlist cannot exceed 1000 entries"))
    (mapcar #'etaf-screensaver--compile-item entries)))

(defun etaf-screensaver--playlist-round (items order random-state)
  "Return one round of ITEMS arranged by ORDER using RANDOM-STATE."
  (let ((count (length items)))
    (pcase order
      ('sequential (copy-sequence items))
      ('random
       (cl-loop repeat count
                collect (nth (cl-random count random-state) items)))
      ('shuffle
       (let ((vec (vconcat items)))
         (cl-loop for i from (1- count) downto 1 do
                  (let* ((j (cl-random (1+ i) random-state))
                         (tmp (aref vec i)))
                    (aset vec i (aref vec j))
                    (aset vec j tmp)))
         (append vec nil)))
      (_ (etaf-screensaver--fail "Unknown playlist order: %S" order)))))

;;; Card framing.

(defun etaf-screensaver--card-side-margin (margin-rows)
  "Return column count matching MARGIN-ROWS line heights in pixels."
  (let* ((metrics (ignore-errors (etaf-display-metrics)))
         (cell-w (max 1 (or (plist-get metrics :char-width) (frame-char-width))))
         (line-h (max 1 (or (plist-get metrics :line-height) (frame-char-height)))))
    (max 1 (round (/ (* margin-rows line-h) (float cell-w))))))

(defun etaf-screensaver--card-echo-rows ()
  "Return visible echo-row height below the presentation window, or 0."
  (let ((win (minibuffer-window)))
    (if (window-live-p win) (window-total-height win) 0)))

(defun etaf-screensaver--layout (style columns rows)
  "Compute layout geometry for STYLE within COLUMNS by ROWS.
Falls back to full canvas when the window is too compact for a card."
  (if (and (eq style 'card) (>= columns 24) (>= rows 10))
      (let* ((top-margin (max 1 (min 3 (/ (- rows 8) 2))))
             (bottom-margin (max 1 (- top-margin (etaf-screensaver--card-echo-rows))))
             (side (max 1 (min (etaf-screensaver--card-side-margin top-margin)
                               (/ (- columns 22) 2))))
             (inner-w (- columns (* 2 side) 2))
             (inner-h (- rows top-margin bottom-margin 4)))
        (list :style 'card :columns columns :rows rows
              :top top-margin :bottom bottom-margin :side side
              :content-w inner-w :content-h inner-h))
    (list :style 'full :columns columns :rows rows
          :top 0 :bottom 0 :side 0 :content-w columns :content-h rows)))

(defun etaf-screensaver--card-template (layout scene background)
  "Build static framing pieces for card LAYOUT of SCENE on BACKGROUND."
  (let* ((cols (plist-get layout :columns))
         (top (plist-get layout :top))
         (bottom (plist-get layout :bottom))
         (side (plist-get layout :side))
         (w (plist-get layout :content-w))
         (colors (etaf-screensaver--card-palette background))
         (paper (plist-get colors :paper))
         (border-face (list :foreground (plist-get colors :border) :background paper))
         (text-face (list :foreground (plist-get colors :text) :background paper))
         (muted-face (list :foreground (plist-get colors :muted) :background paper))
         (mat-face (list :background paper))
         (blank (propertize (make-string cols ?\s) 'face mat-face))
         (pad (propertize (make-string side ?\s) 'face mat-face))
         (bar (propertize "│" 'face border-face))
         (left (concat pad bar))
         (right (concat bar pad))
         (top-border (concat pad (propertize (concat "┌" (make-string w ?─) "┐") 'face border-face) pad))
         (bot-border (concat pad (propertize (concat "└" (make-string w ?─) "┘") 'face border-face) pad))
         (title-row (concat left
                            (propertize
                             (etaf-screensaver--fit-row
                              (concat " " (etaf-screensaver--scene-title scene)) w)
                             'face text-face)
                            right))
         (summary-row (concat left
                              (propertize
                               (etaf-screensaver--fit-row
                                (concat " " (etaf-screensaver--scene-summary scene)) w)
                               'face muted-face)
                              right)))
    (list :top-rows (append (make-list top blank) (list top-border))
          :left left
          :right right
          :bottom-rows (append (list title-row summary-row bot-border)
                               (make-list bottom blank)))))

(defun etaf-screensaver--freeze-rows (rows background)
  "Copy ROWS and bake fallback BACKGROUND face onto every row for reveal."
  (mapcar (lambda (row)
            (let ((copy (copy-sequence row)))
              (add-face-text-property 0 (length copy)
                                      (list :background background) t copy)
              copy))
          rows))

;;; Retained ETAF view and session engine.

(cl-defstruct (etaf-screensaver--session
               (:constructor etaf-screensaver--session-new))
  "Runtime state for one active screensaver presentation."
  scene state item seed random-state
  columns rows window-columns window-rows canvas
  layout card-template
  size revision params ticks elapsed dt
  frame publication published-frame
  previous-rows transition-duration
  runtime buffer)

(etaf-define-component etaf-screensaver--view (&key session)
  "Draw SESSION's retained canvas rows."
  :bindings ((size (etaf-screensaver--session-size session))
             (revision (etaf-screensaver--session-revision session)))
  :view
  (box :width (list 'ch (car (etaf-value size)))
       :height (list 'lh (cdr (etaf-value size)))
       :position 'static :left '(px 0) :top '(lh 0) :z-index 0
       :wrap-mode 'none :overflow 'hidden
       :background-color
       (progn (etaf-value revision)
              (etaf-screensaver--session-background session))
    (box :for (row (progn (etaf-value size) (etaf-value revision)
                          (etaf-screensaver--session-publication session)))
         :key (car row) :height '(lh 1)
      (text :ref (car row) (expr (cdr row))))))

(defun etaf-screensaver--session-background (session)
  "Return SESSION's effective canvas background color."
  (plist-get (etaf-screensaver--session-item session) :background))

(defun etaf-screensaver--session-context (session &optional with-canvas)
  "Build the pure callback context plist for SESSION.
When WITH-CANVAS is non-nil, include SESSION's cleared scratch `:canvas'."
  (let ((rng (etaf-screensaver--session-random-state session))
        (params (etaf-screensaver--session-params session)))
    (append
     (list :columns (etaf-screensaver--session-columns session)
           :rows (etaf-screensaver--session-rows session)
           :seed (etaf-screensaver--session-seed session)
           :tick (etaf-screensaver--session-ticks session)
           :elapsed (etaf-screensaver--session-elapsed session)
           :dt (etaf-screensaver--session-dt session)
           :background (etaf-screensaver--session-background session)
           :params params
           :param (lambda (key)
                    (let ((entry (assq (etaf-screensaver--param-key key) params)))
                      (unless entry
                        (etaf-screensaver--fail "Unknown parameter: %s" key))
                      (cdr entry)))
           :random (lambda (&optional limit)
                     (if limit (cl-random limit rng)
                       (/ (float (cl-random 1000000 rng)) 1000000.0))))
     (when with-canvas
       (list :canvas (etaf-screensaver-canvas-clear
                      (etaf-screensaver--session-canvas session)))))))

(defun etaf-screensaver--session-scene-rows (session)
  "Render SESSION's scene into exact-dimension logical row strings."
  (let* ((scene (etaf-screensaver--session-scene session))
         (raw (funcall (etaf-screensaver--scene-render scene)
                       (etaf-screensaver--session-state session)
                       (etaf-screensaver--session-context session t)))
         (cols (etaf-screensaver--session-columns session))
         (rows (etaf-screensaver--session-rows session)))
    (cond
     ((etaf-screensaver--canvas-p raw)
      (if (and (= (etaf-screensaver--canvas-width raw) cols)
               (= (etaf-screensaver--canvas-height raw) rows))
          (etaf-screensaver-canvas-rows raw)
        (let ((lines (etaf-screensaver-canvas-rows raw)))
          (cl-loop repeat rows
                   for line = (or (pop lines) "")
                   collect (etaf-screensaver--fit-row line cols)))))
     (t
      (let ((lines (cond ((stringp raw) (split-string raw "\n"))
                         ((proper-list-p raw) raw)
                         (t (etaf-screensaver--fail
                             "Scene must render a canvas, string or row list")))))
        (cl-loop repeat rows
                 for line = (or (pop lines) "")
                 collect (progn
                           (unless (stringp line)
                             (etaf-screensaver--fail "Scene rows must be strings"))
                           (etaf-screensaver--fit-row line cols))))))))

(defun etaf-screensaver--session-render (session)
  "Render SESSION, apply optional framing and reveal, and update publication."
  (let* ((content (etaf-screensaver--session-scene-rows session))
         (layout (etaf-screensaver--session-layout session))
         (rows (if (eq (plist-get layout :style) 'card)
                   (let* ((tpl (or (etaf-screensaver--session-card-template session)
                                   (setf (etaf-screensaver--session-card-template session)
                                         (etaf-screensaver--card-template
                                          layout
                                          (etaf-screensaver--session-scene session)
                                          (etaf-screensaver--session-background session)))))
                          (left (plist-get tpl :left))
                          (right (plist-get tpl :right)))
                     (append (plist-get tpl :top-rows)
                             (mapcar (lambda (line) (concat left line right)) content)
                             (plist-get tpl :bottom-rows)))
                 content)))
    (setf (etaf-screensaver--session-frame session) rows)
    (when (etaf-screensaver--session-previous-rows session)
      (let ((progress (/ (etaf-screensaver--session-elapsed session)
                         (etaf-screensaver--session-transition-duration session))))
        (if (>= progress 1.0)
            (setf (etaf-screensaver--session-previous-rows session) nil)
          (let* ((total (etaf-screensaver--session-window-rows session))
                 (revealed (round (* total progress progress (- 3.0 (* 2.0 progress))))))
            (setq rows (append (cl-subseq rows 0 revealed)
                               (nthcdr revealed (etaf-screensaver--session-previous-rows session))))
            (setf (etaf-screensaver--session-frame session) rows)))))
    (let ((previous (etaf-screensaver--session-publication session)))
      (setf (etaf-screensaver--session-publication session)
            (mapcar (lambda (row)
                      (cons (or (car (pop previous)) (make-symbol "screensaver-row"))
                            row))
                    rows)))))

(defun etaf-screensaver--session-select (session item seed &optional transition)
  "Switch SESSION to ITEM at SEED, with optional TRANSITION reveal seconds."
  (when (etaf-screensaver--session-previous-rows session)
    (setf (etaf-screensaver--session-previous-rows session) nil)
    (etaf-screensaver--session-render session))
  (let* ((previous (when (and transition (> transition 0)
                              (etaf-screensaver--session-frame session)
                              (not (equal item (etaf-screensaver--session-item session))))
                     (etaf-screensaver--freeze-rows
                      (etaf-screensaver--session-frame session)
                      (etaf-screensaver--session-background session))))
         (layout (etaf-screensaver--layout
                  (plist-get item :frame)
                  (etaf-screensaver--session-window-columns session)
                  (etaf-screensaver--session-window-rows session)))
         (cw (plist-get layout :content-w))
         (ch (plist-get layout :content-h))
         (scene (plist-get item :definition))
         (create (etaf-screensaver--scene-create scene)))
    (setf (etaf-screensaver--session-layout session) layout
          (etaf-screensaver--session-card-template session) nil
          (etaf-screensaver--session-previous-rows session) previous
          (etaf-screensaver--session-transition-duration session)
          (and previous (min transition (/ (plist-get item :duration) 2.0)))
          (etaf-screensaver--session-columns session) cw
          (etaf-screensaver--session-rows session) ch
          (etaf-screensaver--session-canvas session) (etaf-screensaver-canvas-create cw ch)
          (etaf-screensaver--session-item session) item
          (etaf-screensaver--session-scene session) scene
          (etaf-screensaver--session-seed session) seed
          (etaf-screensaver--session-random-state session) (cl-make-random-state seed)
          (etaf-screensaver--session-params session) (plist-get item :params)
          (etaf-screensaver--session-ticks session) 0
          (etaf-screensaver--session-elapsed session) 0.0
          (etaf-screensaver--session-dt session) 0.0
          (etaf-screensaver--session-published-frame session) nil
          (etaf-screensaver--session-state session)
          (when create (funcall create (etaf-screensaver--session-context session)))))
  (etaf-screensaver--session-render session)
  (cl-incf (etaf-value (etaf-screensaver--session-revision session))))

(defun etaf-screensaver--session-create (item seed columns rows buffer)
  "Create a new session for ITEM at SEED in COLUMNS by ROWS for BUFFER."
  (let ((session (etaf-screensaver--session-new
                  :window-columns columns :window-rows rows :buffer buffer
                  :size (etaf-ref (cons columns rows))
                  :revision (etaf-ref 0))))
    (etaf-screensaver--session-select session item seed)
    session))

(defun etaf-screensaver--session-publish (session)
  "Publish SESSION's changed rows in one batched retained Host update."
  (let ((runtime (etaf-screensaver--session-runtime session))
        (publication (etaf-screensaver--session-publication session))
        (previous (etaf-screensaver--session-published-frame session))
        updates)
    (when (and runtime (etaf-runtime-mounted-p runtime))
      (dolist (row publication)
        (let ((old (pop previous)))
          (unless (and (eq (car row) (car old))
                       (equal-including-properties (cdr row) (cdr old)))
            (push row updates))))
      (when updates
        (etaf-runtime-update-host-contents runtime (nreverse updates))
        (setf (etaf-screensaver--session-published-frame session) publication)))))

(defun etaf-screensaver--session-step (session dt)
  "Advance SESSION by DT seconds without publishing."
  (setf (etaf-screensaver--session-dt session) dt)
  (when-let* ((step (etaf-screensaver--scene-step
                     (etaf-screensaver--session-scene session))))
    (funcall step (etaf-screensaver--session-state session)
             (etaf-screensaver--session-context session)))
  (cl-incf (etaf-screensaver--session-ticks session))
  (cl-incf (etaf-screensaver--session-elapsed session) dt))

(defun etaf-screensaver--session-advance (session dt)
  "Advance SESSION by DT seconds, render and publish changed rows."
  (etaf-screensaver--session-step session dt)
  (etaf-screensaver--session-render session)
  (etaf-screensaver--session-publish session))

(defun etaf-screensaver--session-resize (session columns rows)
  "Resize SESSION to window size COLUMNS by ROWS."
  (unless (and (= columns (etaf-screensaver--session-window-columns session))
               (= rows (etaf-screensaver--session-window-rows session)))
    (let* ((layout (etaf-screensaver--layout
                    (plist-get (etaf-screensaver--session-item session) :frame)
                    columns rows))
           (cw (plist-get layout :content-w))
           (ch (plist-get layout :content-h))
           (content-changed (or (/= cw (etaf-screensaver--session-columns session))
                                (/= ch (etaf-screensaver--session-rows session)))))
      (setf (etaf-screensaver--session-previous-rows session) nil
            (etaf-screensaver--session-window-columns session) columns
            (etaf-screensaver--session-window-rows session) rows
            (etaf-screensaver--session-layout session) layout
            (etaf-screensaver--session-card-template session) nil
            (etaf-screensaver--session-columns session) cw
            (etaf-screensaver--session-rows session) ch
            (etaf-screensaver--session-canvas session) (etaf-screensaver-canvas-create cw ch))
      (when content-changed
        (let* ((scene (etaf-screensaver--session-scene session))
               (resize (etaf-screensaver--scene-resize scene))
               (create (etaf-screensaver--scene-create scene)))
          (cond
           (resize
            (setf (etaf-screensaver--session-state session)
                  (funcall resize (etaf-screensaver--session-state session)
                           (etaf-screensaver--session-context session))))
           (create
            (setf (etaf-screensaver--session-random-state session)
                  (cl-make-random-state (etaf-screensaver--session-seed session))
                  (etaf-screensaver--session-state session)
                  (funcall create (etaf-screensaver--session-context session)))))))
      (etaf-screensaver--session-render session)
      (setf (etaf-value (etaf-screensaver--session-size session)) (cons columns rows))
      (when-let* ((runtime (etaf-screensaver--session-runtime session)))
        (etaf-runtime-flush runtime)
        (etaf-screensaver--session-publish session)))))

(provide 'etaf-screensaver-engine)
;;; etaf-screensaver-engine.el ends here
