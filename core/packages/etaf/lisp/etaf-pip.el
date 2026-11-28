;;; etaf-pip.el --- Floating Picture-in-Picture child-frame host -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Shared floating Picture-in-Picture (PiP) host for ETAF applications.
;; Owns the recycled graphical child frame (avoiding macOS `NSTextInputContext'
;; crashes on `delete-frame'), 4px draggable resize border, native-draggable
;; adaptive `header-line-format', focus-reactive frame border, 4-corner docking,
;; S/M/L size presets, and zero-pin live viewport synchronization so manual
;; edge/corner drag-resizing dynamically adapts both the mounted View and any
;; embedded native GPU `etaf-video' layer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-runtime)
(require 'etaf-viewport)

(declare-function etaf-video--sync-all-gpu-instances "etaf-video-component" ())

(defconst etaf-pip--presets
  '((small  :label "小" :cols 42)
    (medium :label "中" :cols 60)
    (large  :label "大" :cols 78))
  "Default S/M/L size presets for a floating Picture-in-Picture window.")

(defconst etaf-pip--corners
  '(bottom-right bottom-left top-left top-right)
  "Clockwise corner docking order inside the enclosing top-level frame.")

(defvar etaf-pip--entries (make-hash-table :test #'eq)
  "Active PiP host records keyed by symbol ID.")

(defvar etaf-pip--frame-pool nil
  "Parked graphical child frames awaiting reuse across PiP sessions.")

(defvar etaf-pip--syncing nil
  "Non-nil while programmatically resizing a PiP child frame.")

(cl-defstruct (etaf-pip--entry (:constructor etaf-pip--entry--make))
  "Owned state of one active floating Picture-in-Picture host."
  id frame parent-frame buffer
  bounds-ref size-key corner
  title theme return-fn close-fn resize-fn size-change-fn corner-change-fn
  focus-hook resize-hook poll-timer sync-timer
  last-body-px closing)

(defun etaf-pip--validate-id (id)
  "Require ID to be a non-nil symbol."
  (unless (and id (symbolp id))
    (signal 'wrong-type-argument (list 'symbolp id)))
  id)

(defun etaf-pip--top-frame (&optional frame)
  "Return the top-level frame enclosing FRAME so PiP never nests in a child."
  (let ((fr (or frame (selected-frame))))
    (while (and (frame-live-p fr) (frame-parent fr))
      (setq fr (frame-parent fr)))
    (if (frame-live-p fr) fr (selected-frame))))

(defun etaf-pip--preset (size-key)
  "Return preset plist for SIZE-KEY (`small', `medium' or `large')."
  (or (cdr (assq size-key etaf-pip--presets))
      (cdr (assq 'medium etaf-pip--presets))))

(defun etaf-pip--resolve (source &optional fallback)
  "Resolve string/plist/ref/computed/function SOURCE, or FALLBACK."
  (let ((val (cond ((null source) nil)
                   ((or (etaf-ref-p source) (etaf-computed-p source))
                    (etaf-value source))
                   ((functionp source) (ignore-errors (funcall source)))
                   (t source))))
    (if val val fallback)))

(defun etaf-pip--theme-colors (entry)
  "Return normalized theme color plist for ENTRY."
  (let ((raw (etaf-pip--resolve (etaf-pip--entry-theme entry))))
    (list :bg (or (plist-get raw :bg) "#15171F")
          :stage (or (plist-get raw :stage) "#050607")
          :panel (or (plist-get raw :panel) (plist-get raw :bg) "#15171F")
          :chip (or (plist-get raw :chip) "#232836")
          :hover (or (plist-get raw :hover) "#2D3345")
          :ink (or (plist-get raw :ink) "#F1F3F8")
          :muted (or (plist-get raw :muted) "#9AA3B2")
          :accent (or (plist-get raw :accent) "#4C8DFF")
          :accent-soft (or (plist-get raw :accent-soft) "#1D2E52")
          :border-inactive (or (plist-get raw :border-inactive) "#2D364A"))))

(defun etaf-pip--truncate (text max-cols)
  "Truncate TEXT to at most MAX-COLS display columns with an ellipsis."
  (let ((str (or text "")))
    (if (<= (string-width str) max-cols)
        str
      (let ((limit (max 1 (1- max-cols)))
            (acc "")
            (w 0)
            (i 0)
            (len (length str)))
        (while (and (< i len)
                    (<= (+ w (char-width (aref str i))) limit))
          (setq w (+ w (char-width (aref str i)))
                acc (concat acc (substring str i (1+ i)))
                i (1+ i)))
        (concat acc "…")))))

(defun etaf-pip--cell (entry)
  "Return `(CHAR-WIDTH . LINE-HEIGHT)' pixels for ENTRY's PiP canvas."
  (let* ((buf (etaf-pip--entry-buffer entry))
         (fr (etaf-pip--entry-frame entry))
         (parent (etaf-pip--entry-parent-frame entry))
         (rt (and buf (buffer-live-p buf) (etaf-runtime-for-buffer buf)))
         (metrics (and rt (ignore-errors (etaf-display-metrics rt))))
         (ref-fr (cond ((and fr (frame-live-p fr)) fr)
                       ((and parent (frame-live-p parent)) parent)
                       (t (selected-frame))))
         (cw (max 1 (or (plist-get metrics :char-width)
                        (and ref-fr (frame-char-width ref-fr))
                        8)))
         (lh (max 1 (or (plist-get metrics :line-height)
                        (and ref-fr (frame-char-height ref-fr))
                        16))))
    (cons cw lh)))

(defun etaf-pip--mix-color (base accent strength)
  "Blend hex colors BASE and ACCENT with ACCENT weight STRENGTH (0.0..1.0)."
  (let ((c1 (and (stringp base) (color-name-to-rgb base)))
        (c2 (and (stringp accent) (color-name-to-rgb accent)))
        (s (max 0.0 (min 1.0 (float (or strength 0.6))))))
    (if (and c1 c2)
        (apply #'format "#%02X%02X%02X"
               (cl-mapcar (lambda (a b)
                            (max 0 (min 255 (round (* 255.0 (+ (* (- 1.0 s) a) (* s b)))))))
                          c1 c2))
      (or accent base "#4C8DFF"))))

(defun etaf-pip--preset-geometry (entry)
  "Compute target 16:9 preset pixel geometry plist for ENTRY."
  (let* ((preset (etaf-pip--preset (etaf-pip--entry-size-key entry)))
         (cols (plist-get preset :cols))
         (cell (etaf-pip--cell entry))
         (cw (car cell))
         (lh (cdr cell))
         (px-w (* cols cw))
         ;; Exact 16:9 video height + 3-row transport deck (seek + controls + 1 bottom row).
         (vrows (max 6 (round (/ (float px-w) (/ 16.0 9.0) lh))))
         (rows (+ vrows 3))
         (fr (etaf-pip--entry-frame entry))
         (win (and fr (frame-live-p fr) (frame-root-window fr)))
         (header-px (or (and win (window-live-p win)
                             (> (window-header-line-height win) 0)
                             (window-header-line-height win))
                        (+ lh 10)))
         (px-h (+ (* rows lh) header-px))
         (parent (or (etaf-pip--entry-parent-frame entry) (etaf-pip--top-frame)))
         (pe (and parent (frame-live-p parent) (frame-edges parent 'inner-edges)))
         (pw (if pe (- (nth 2 pe) (nth 0 pe))
               (if (and parent (frame-live-p parent)) (frame-pixel-width parent) 1280)))
         (ph (if pe (- (nth 3 pe) (nth 1 pe))
               (if (and parent (frame-live-p parent)) (frame-pixel-height parent) 800)))
         (mx 20)
         (mtop 42)
         (mbot (+ 28 (* 2 lh)))
         (corner (or (etaf-pip--entry-corner entry) 'bottom-right))
         (x (pcase corner
              ((or 'bottom-left 'top-left) mx)
              (_ (max mx (- pw px-w mx)))))
         (y (pcase corner
              ((or 'top-left 'top-right) mtop)
              (_ (max mtop (- ph px-h mbot))))))
    (list :cols cols :rows rows :cell-w cw :cell-h lh
          :width-px px-w :height-px (* rows lh)
          :frame-px-w px-w :frame-px-h px-h
          :left x :top y)))

(defun etaf-pip--header-btn (label face hover-face help action)
  "Return a clickable `header-line-format' control that never hijacks dragging."
  (let ((map (make-sparse-keymap))
        (fn (lambda () (interactive) (funcall action))))
    (define-key map [header-line down-mouse-1] #'ignore)
    (define-key map [header-line mouse-1] fn)
    (define-key map [mouse-1] fn)
    (propertize label
                'face face
                'mouse-face hover-face
                'pointer 'hand
                'help-echo help
                'keymap map)))

(defun etaf-pip--header-format (entry)
  "Build adaptive native-draggable `header-line-format' for ENTRY."
  (let* ((colors (etaf-pip--theme-colors entry))
         (bg (plist-get colors :panel))
         (bg-chip (plist-get colors :chip))
         (bg-hover (plist-get colors :hover))
         (fg (plist-get colors :ink))
         (muted (plist-get colors :muted))
         (accent (plist-get colors :accent))
         (accent-bg (plist-get colors :accent-soft))
         (bar-box (list :line-width '(0 . 5) :color bg :style nil))
         (chip-box (list :line-width '(2 . 2) :color bg-chip :style nil))
         (hover-box (list :line-width '(2 . 2) :color bg-hover :style nil))
         (ret-box (list :line-width '(2 . 2) :color accent-bg :style nil))
         (ret-hbox (list :line-width '(2 . 2) :color accent :style nil))
         (base-face (list :background bg :foreground fg :weight 'bold
                          :height 1.0 :inverse-video nil :box bar-box))
         (dim-face (list :background bg :foreground muted
                         :height 1.0 :inverse-video nil :box bar-box))
         (chip-face (list :background bg-chip :foreground fg
                          :height 1.0 :inverse-video nil :box chip-box))
         (hover-face (list :background bg-hover :foreground fg
                           :height 1.0 :inverse-video nil :box hover-box))
         (ret-face (list :background accent-bg :foreground accent :weight 'bold
                         :height 1.0 :inverse-video nil :box ret-box))
         (ret-hover (list :background accent :foreground "#FFFFFF" :weight 'bold
                          :height 1.0 :inverse-video nil :box ret-hbox))
         (bounds (etaf-value (etaf-pip--entry-bounds-ref entry)))
         (cols (max 16 (or (plist-get bounds :cols) 48)))
         (tiny (< cols 38))
         (compact (< cols 52))
         (id (etaf-pip--entry-id entry))
         (preset (etaf-pip--preset (etaf-pip--entry-size-key entry)))
         (title (or (let ((tval (etaf-pip--resolve (etaf-pip--entry-title entry))))
                      (and (stringp tval) (not (string-empty-p tval)) tval))
                    "画中画"))
         (sep (propertize " " 'face dim-face))
         (icon-face (list :background bg
                          :foreground (etaf-pip--mix-color muted fg 0.35)
                          :height 1.0 :inverse-video nil :box bar-box))
         ;; Trailing space aligns `×' ink with the shared optical right margin
         ;; (`1ch' on compact, `2ch' on standard/wide; `" × "' already ends in 1ch).
         (tail (if compact "" (propertize " " 'face (append dim-face '(:extend t)))))
         (b-size (unless tiny
                   (etaf-pip--header-btn
                    (format " %s " (plist-get preset :label))
                    chip-face hover-face "切换窗口大小 小 / 中 / 大 (s)"
                    (lambda () (etaf-pip-cycle-size id)))))
         (b-corner (unless tiny
                     (etaf-pip--header-btn
                      " ⊞ " icon-face hover-face "顺时针停靠四角 (p)"
                      (lambda () (etaf-pip-cycle-corner id)))))
         (b-ret (when (etaf-pip--entry-return-fn entry)
                  (etaf-pip--header-btn
                   (if compact " ↩ " " ↩ 主 ")
                   ret-face ret-hover "回到主界面继续播放 (r / b)"
                   (lambda ()
                     (when-let* ((fn (etaf-pip--entry-return-fn entry)))
                       (funcall fn))))))
         (b-close (etaf-pip--header-btn
                   " × " icon-face hover-face "关闭画中画 (q / v)"
                   (lambda () (etaf-pip-close id t))))
         (parts (delq nil (list b-size b-corner b-ret b-close)))
         (right (concat (mapconcat #'identity parts sep) tail))
         (right-px (if (fboundp 'string-pixel-width)
                       (max 1 (string-pixel-width right))
                     (* 8 (string-width right))))
         (grip (propertize (if compact " ⋮⋮ " "  ⋮⋮ ") 'face dim-face
                           'help-echo "按住标题栏拖动窗口；拖拽四边或四角可自由缩放"))
         (budget (max 4 (- cols (string-width grip) (string-width right) 2)))
         (shown (etaf-pip--truncate title budget))
         (title-part (propertize shown
                                 'face base-face
                                 'help-echo "按住标题栏拖动窗口；拖拽四边或四角可自由缩放"))
         (spacer (propertize " "
                             'face (append base-face '(:extend t))
                             'display (list 'space :align-to
                                            (list '- 'right (list right-px)))
                             'help-echo "按住标题栏拖动窗口；拖拽四边或四角可自由缩放")))
    (concat grip title-part spacer right)))

(defun etaf-pip--paint-border (entry)
  "Update ENTRY's 1px child-frame hairline border for focused vs resting state."
  (when-let* ((fr (etaf-pip--entry-frame entry))
              ((frame-live-p fr)))
    (let* ((colors (etaf-pip--theme-colors entry))
           (focused (eq (selected-frame) fr))
           (strength 0.60)
           (col (if focused
                    (etaf-pip--mix-color (plist-get colors :panel)
                                         (plist-get colors :accent)
                                         strength)
                  (plist-get colors :border-inactive)))
           (face (if (facep 'child-frame-border) 'child-frame-border 'internal-border)))
      (unless (equal col (face-attribute face :background fr))
        (set-face-background face col fr)))))

(defun etaf-pip--schedule-gpu-sync ()
  "Synchronize native GPU video overlays now and after Emacs settles redisplay."
  (when (fboundp 'etaf-video--sync-all-gpu-instances)
    (ignore-errors (etaf-video--sync-all-gpu-instances))
    (dolist (delay '(0.02 0.09))
      (run-at-time delay nil
                   (lambda ()
                     (ignore-errors (etaf-video--sync-all-gpu-instances)))))))

(defun etaf-pip--sync-bounds (entry &optional force)
  "Measure ENTRY's live window pixels and adapt bounds, refit, header and GPU."
  (when (and entry (not (etaf-pip--entry-closing entry)))
    (let* ((fr (etaf-pip--entry-frame entry))
           (buf (etaf-pip--entry-buffer entry))
           (win (and fr (frame-live-p fr) (frame-root-window fr))))
      (when (and buf (buffer-live-p buf) win (window-live-p win))
        (let* ((cell (etaf-pip--cell entry))
               (cw (car cell))
               (lh (cdr cell))
               (raw-w (or (window-body-width win t) (frame-text-width fr) 320))
               (raw-h (or (window-body-height win t) (- (frame-text-height fr) 28) 160))
               (body-w (max 140 raw-w))
               (body-h (max (* 4 lh) raw-h))
               (px-key (cons body-w body-h)))
          (when (or force (not (equal px-key (etaf-pip--entry-last-body-px entry))))
            (setf (etaf-pip--entry-last-body-px entry) px-key)
            ;; Keep resized child frame inside its parent frame and visible display.
            (when-let* ((parent (and fr (frame-live-p fr) (frame-parent fr)))
                        ((frame-live-p parent)))
              (let* ((pe (frame-edges parent 'inner-edges))
                     (pw (if pe (- (nth 2 pe) (nth 0 pe)) (frame-inner-width parent)))
                     (ph (if pe (- (nth 3 pe) (nth 1 pe)) (frame-inner-height parent)))
                     (work (alist-get 'workarea (frame-monitor-attributes parent)))
                     (mon-r (if work (+ (nth 0 work) (nth 2 work)) 10000))
                     (mon-b (if work (+ (nth 1 work) (nth 3 work)) 10000))
                     (vis-w (if pe (min pw (- mon-r (nth 0 pe))) pw))
                     (vis-h (if pe (min ph (- mon-b (nth 1 pe))) ph))
                     (fw (frame-pixel-width fr))
                     (fh (frame-pixel-height fr))
                     (pos (frame-position fr))
                     (fx (car pos))
                     (fy (cdr pos))
                     (max-x (max 8 (- vis-w fw 12)))
                     (max-y (max 24 (- vis-h fh 12)))
                     (nx (max 0 (min fx max-x)))
                     (ny (max 0 (min fy max-y))))
                (when (or (/= nx fx) (/= ny fy))
                  (let ((etaf-pip--syncing t))
                    (set-frame-position fr nx ny)))))
            (let* ((cols (max 16 (floor body-w cw)))
                   (rows (max 4 (floor body-h lh)))
                   (bounds (list :width-px body-w
                                 :height-px body-h
                                 :cols cols
                                 :rows rows
                                 :cell-w cw
                                 :cell-h lh
                                 :size (etaf-pip--entry-size-key entry)
                                 :corner (etaf-pip--entry-corner entry))))
              (etaf-set-value (etaf-pip--entry-bounds-ref entry) bounds)
              (with-current-buffer buf
                (setq-local header-line-format (etaf-pip--header-format entry)))
              (when-let* ((rt (etaf-runtime-for-buffer buf)))
                (ignore-errors (etaf-refit rt win))
                (ignore-errors (etaf-runtime-flush rt)))
              (etaf-pip--schedule-gpu-sync)
              (when-let* ((cb (etaf-pip--entry-resize-fn entry)))
                (ignore-errors (funcall cb bounds))))))))))

(defun etaf-pip--on-resize-event (entry _arg)
  "Coalesced resize handler for ENTRY across window/frame change hooks."
  (when (and entry (not etaf-pip--syncing) (not (etaf-pip--entry-closing entry)))
    (when-let* ((old (etaf-pip--entry-sync-timer entry)))
      (cancel-timer old)
      (setf (etaf-pip--entry-sync-timer entry) nil))
    ;; Sync immediately on small changes and re-verify once drag settles.
    (etaf-pip--sync-bounds entry)
    (setf (etaf-pip--entry-sync-timer entry)
          (run-at-time 0.04 nil
                       (lambda (e)
                         (when (eq e (gethash (etaf-pip--entry-id e) etaf-pip--entries))
                           (setf (etaf-pip--entry-sync-timer e) nil)
                           (etaf-pip--sync-bounds e)))
                       entry))))

(defun etaf-pip--on-display-window-change (buffer _window)
  "Synchronize any PiP host whose mounted buffer is BUFFER."
  (maphash (lambda (_id entry)
             (when (eq (etaf-pip--entry-buffer entry) buffer)
               (etaf-pip--sync-bounds entry)))
           etaf-pip--entries))

(add-hook 'ebox-display-window-change-functions #'etaf-pip--on-display-window-change)

(defun etaf-pip--reposition (entry)
  "Dock ENTRY's floating frame into its active corner, preserving live size."
  (when-let* ((fr (etaf-pip--entry-frame entry))
              ((frame-live-p fr)))
    (let* ((parent (or (etaf-pip--entry-parent-frame entry) (etaf-pip--top-frame fr)))
           (pw (frame-pixel-width parent))
           (ph (frame-pixel-height parent))
           (lh (cdr (etaf-pip--cell entry)))
           (mx 20)
           (mtop 42)
           (mbot (+ 28 (* 2 lh)))
           (fw (frame-pixel-width fr))
           (fh (frame-pixel-height fr))
           (corner (or (etaf-pip--entry-corner entry) 'bottom-right))
           (x (pcase corner
                ((or 'bottom-left 'top-left) mx)
                (_ (max mx (- pw fw mx)))))
           (y (pcase corner
                ((or 'top-left 'top-right) mtop)
                (_ (max mtop (- ph fh mbot))))))
      (set-frame-position fr x y)
      (etaf-pip--schedule-gpu-sync))))

(defun etaf-pip--acquire-frame (parent geo bg fg)
  "Acquire a recycled graphical child frame for PARENT, or create one."
  (setq etaf-pip--frame-pool
        (cl-remove-if-not (lambda (f)
                            (and (frame-live-p f)
                                 (display-graphic-p f)
                                 (frame-parent f)))
                          etaf-pip--frame-pool))
  (let* ((params `((parent-frame . ,parent)
                   (minibuffer . nil)
                   (undecorated . t)
                   (tab-bar-lines . 0)
                   (tool-bar-lines . 0)
                   (menu-bar-lines . 0)
                   (left-fringe . 0)
                   (right-fringe . 0)
                   (vertical-scroll-bars . nil)
                   (horizontal-scroll-bars . nil)
                   (border-width . 0)
                   (internal-border-width . 1)
                   (child-frame-border-width . 1)
                   (line-spacing . 0)
                   (drag-with-header-line . t)
                   (drag-internal-border . t)
                   (top-visible . 24)
                   (snap-width . 12)
                   (z-group . above)
                   (no-other-frame . t)
                   (no-accept-focus . nil)
                   (background-color . ,bg)
                   (foreground-color . ,fg)))
         (pooled (cl-find-if (lambda (f) (eq (frame-parent f) parent))
                             etaf-pip--frame-pool)))
    (if pooled
        (progn
          (setq etaf-pip--frame-pool (delq pooled etaf-pip--frame-pool))
          (modify-frame-parameters pooled params)
          (let ((frame-resize-pixelwise t))
            (set-frame-size pooled
                            (plist-get geo :frame-px-w)
                            (plist-get geo :frame-px-h) t))
          (set-frame-position pooled (plist-get geo :left) (plist-get geo :top))
          (unless (frame-visible-p pooled)
            (make-frame-visible pooled))
          pooled)
      (make-frame
       (append params
               `((width . (text-pixels . ,(plist-get geo :frame-px-w)))
                 (height . (text-pixels . ,(plist-get geo :frame-px-h)))
                 (left . ,(plist-get geo :left))
                 (top . ,(plist-get geo :top))))))))

;;;###autoload
(cl-defun etaf-pip-open
    (id view &key title parent (size 'medium) (corner 'bottom-right)
        theme on-return on-close on-resize on-size-change on-corner-change)
  "Open a floating adaptive Picture-in-Picture window for symbol ID showing VIEW.
If a PiP window for ID is already open, it closes first.

TITLE is a string, ref, computed or zero-argument function for the draggable
header bar.  PARENT is the enclosing top-level frame (default selected frame).
SIZE is `small', `medium' (default) or `large'; CORNER is `bottom-right'
(default), `bottom-left', `top-left' or `top-right'.  THEME is a color plist
or zero-argument function returning `:bg', `:panel', `:chip', `:hover', `:ink',
`:muted', `:accent', `:accent-soft' and `:border-inactive'.

ON-RETURN runs when the user activates the header return control.  ON-CLOSE
runs once when the PiP window closes.  ON-RESIZE runs with the live bounds
plist whenever the window resizes.  ON-SIZE-CHANGE and ON-CORNER-CHANGE run
with the new preset symbol when cycled via `etaf-pip-cycle-size' or
`etaf-pip-cycle-corner'.  Returns the PiP buffer."
  (etaf-pip--validate-id id)
  (when (gethash id etaf-pip--entries)
    (etaf-pip-close id nil))
  (let* ((top-parent (etaf-pip--top-frame parent))
         (size-key (if (memq size '(small medium large)) size 'medium))
         (corner-key (if (memq corner etaf-pip--corners) corner 'bottom-right))
         (buf (generate-new-buffer (format "*PiP: %s*" id)))
         (bounds-ref (etaf-ref nil :test #'equal :name (intern (format "etaf-pip-bounds-%s" id))))
         (entry (etaf-pip--entry--make
                 :id id
                 :parent-frame top-parent
                 :buffer buf
                 :bounds-ref bounds-ref
                 :size-key size-key
                 :corner corner-key
                 :title title
                 :theme theme
                 :return-fn on-return
                 :close-fn on-close
                 :resize-fn on-resize
                 :size-change-fn on-size-change
                 :corner-change-fn on-corner-change))
         (colors (etaf-pip--theme-colors entry))
         (bg (plist-get colors :panel))
         (fg (plist-get colors :ink))
         (geo (etaf-pip--preset-geometry entry))
         (graphic (and (display-graphic-p top-parent) (not noninteractive)))
         (fr nil))
    (puthash id entry etaf-pip--entries)
    (etaf-set-value
     bounds-ref
     (list :width-px (plist-get geo :width-px)
           :height-px (plist-get geo :height-px)
           :cols (plist-get geo :cols)
           :rows (plist-get geo :rows)
           :cell-w (plist-get geo :cell-w)
           :cell-h (plist-get geo :cell-h)
           :size size-key
           :corner corner-key))
    (when graphic
      (let ((etaf-pip--syncing t))
        (setq fr (etaf-pip--acquire-frame top-parent geo bg fg))
        (setf (etaf-pip--entry-frame entry) fr)
        (set-window-buffer (frame-root-window fr) buf)
        (set-window-fringes (frame-root-window fr) 0 0)
        (set-window-scroll-bars (frame-root-window fr) 0 nil nil)
        (let ((frame-resize-pixelwise t))
          (set-frame-size fr (plist-get geo :frame-px-w)
                          (plist-get geo :frame-px-h) t))
        (set-frame-position fr (plist-get geo :left) (plist-get geo :top))))
    (with-current-buffer buf
      (setq-local mode-line-format nil
                  line-spacing 0
                  cursor-type nil
                  truncate-lines t
                  scroll-margin 0
                  hscroll-margin 0
                  scroll-conservatively 0
                  auto-hscroll-mode nil
                  buffer-display-table
                  (let ((tbl (copy-sequence (or standard-display-table
                                                (make-display-table)))))
                    (set-display-table-slot tbl 'truncation ?\s)
                    tbl)
                  header-line-format (etaf-pip--header-format entry))
      (when (bound-and-true-p display-line-numbers-mode)
        (display-line-numbers-mode -1))
      (face-remap-set-base 'default (list :background (plist-get colors :stage)
                                          :foreground fg))
      (face-remap-set-base 'header-line (list :background bg :foreground fg
                                              :box nil :inherit nil))
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (when (eq entry (gethash id etaf-pip--entries))
                    (etaf-pip-close id nil)))
                -50 t))
    ;; Mount WITHOUT pinning viewport dimensions so Ebox tracks every drag natively.
    (etaf-mount buf view)
    (when graphic
      (ignore-errors (select-frame-set-input-focus fr))
      (etaf-pip--paint-border entry)
      ;; Re-snap height once with the real rendered header-line pixel height so
      ;; presets have zero extra dead pixels below the 1-row bottom cushion.
      (when-let* ((win (frame-root-window fr))
                  ((window-live-p win))
                  (hdr-h (window-header-line-height win))
                  ((> hdr-h 0)))
        (let* ((cell (etaf-pip--cell entry))
               (exact-h (+ (* (plist-get geo :rows) (cdr cell)) hdr-h))
               (etaf-pip--syncing t)
               (frame-resize-pixelwise t))
          (when (/= exact-h (plist-get geo :frame-px-h))
            (set-frame-size fr (plist-get geo :frame-px-w) exact-h t))))
      (etaf-pip--sync-bounds entry t)
      (let ((focus-fn (lambda (&rest _)
                        (when (eq entry (gethash id etaf-pip--entries))
                          (etaf-pip--paint-border entry)
                          (etaf-pip--on-resize-event entry nil))))
            (resize-fn (lambda (arg)
                         (when (eq entry (gethash id etaf-pip--entries))
                           (etaf-pip--on-resize-event entry arg)))))
        (setf (etaf-pip--entry-focus-hook entry) focus-fn
              (etaf-pip--entry-resize-hook entry) resize-fn)
        (add-function :after after-focus-change-function focus-fn)
        (add-hook 'window-configuration-change-hook focus-fn)
        (with-current-buffer buf
          (add-hook 'window-size-change-functions resize-fn nil t))
        ;; Lightweight live geometry check catches OS/mouse-drag resizes reliably.
        (setf (etaf-pip--entry-poll-timer entry)
              (run-at-time 0.12 0.12
                           (lambda (e)
                             (if (not (eq e (gethash (etaf-pip--entry-id e) etaf-pip--entries)))
                                 (when-let* ((tm (etaf-pip--entry-poll-timer e)))
                                   (cancel-timer tm))
                               (let ((f (etaf-pip--entry-frame e)))
                                 (if (not (and f (frame-live-p f)))
                                     (etaf-pip-close (etaf-pip--entry-id e) nil)
                                   (etaf-pip--paint-border e)
                                   (etaf-pip--sync-bounds e)))))
                           entry))))
    buf))

;;;###autoload
(defun etaf-pip-close (id &optional restore-focus)
  "Close the floating Picture-in-Picture window ID and return non-nil if open.
With RESTORE-FOCUS non-nil, return input focus to the parent frame."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries)))
    (unless (etaf-pip--entry-closing entry)
      (setf (etaf-pip--entry-closing entry) t)
      (remhash id etaf-pip--entries)
      (when-let* ((tm (etaf-pip--entry-poll-timer entry)))
        (cancel-timer tm)
        (setf (etaf-pip--entry-poll-timer entry) nil))
      (when-let* ((tm (etaf-pip--entry-sync-timer entry)))
        (cancel-timer tm)
        (setf (etaf-pip--entry-sync-timer entry) nil))
      (when-let* ((hk (etaf-pip--entry-focus-hook entry)))
        (remove-function after-focus-change-function hk)
        (remove-hook 'window-configuration-change-hook hk)
        (setf (etaf-pip--entry-focus-hook entry) nil))
      (when-let* ((cb (etaf-pip--entry-close-fn entry)))
        (ignore-errors (funcall cb)))
      (let ((fr (etaf-pip--entry-frame entry))
            (parent (etaf-pip--entry-parent-frame entry))
            (buf (etaf-pip--entry-buffer entry))
            (had-focus nil))
        (when (and fr (frame-live-p fr))
          (setq had-focus (eq (selected-frame) fr))
          (when (and (or restore-focus had-focus) parent (frame-live-p parent))
            (ignore-errors (select-frame-set-input-focus parent)))
          (when (frame-visible-p fr)
            (ignore-errors (make-frame-invisible fr)))
          (when-let* ((win (frame-root-window fr)))
            (when (window-live-p win)
              (ignore-errors (set-window-dedicated-p win nil))
              (ignore-errors (set-window-buffer win (get-buffer-create " *etaf-pip-park*"))))))
        (when (and buf (buffer-live-p buf))
          (when-let* ((rt (etaf-runtime-for-buffer buf)))
            (ignore-errors (etaf-unmount rt)))
          (ignore-errors (kill-buffer buf)))
        (when (and fr (frame-live-p fr))
          (if (and (display-graphic-p fr) (frame-parent fr))
              (progn
                (ignore-errors (set-frame-parameter fr 'no-accept-focus t))
                (setq etaf-pip--frame-pool
                      (cons fr (delq fr etaf-pip--frame-pool))))
            (ignore-errors (delete-frame fr))))))
    t))

;;;###autoload
(defun etaf-pip-active-p (id)
  "Return non-nil when floating Picture-in-Picture window ID is active."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries)))
    (and (not (etaf-pip--entry-closing entry))
         (buffer-live-p (etaf-pip--entry-buffer entry))
         (or (null (etaf-pip--entry-frame entry))
             (frame-live-p (etaf-pip--entry-frame entry)))
         t)))

;;;###autoload
(defun etaf-pip-bounds (id)
  "Return reactive live inner bounds plist of Picture-in-Picture window ID.
Keys are `:width-px', `:height-px', `:cols', `:rows', `:cell-w', `:cell-h',
`:size' and `:corner'.  Reading this inside a Component `:render' subscribes
that Component to every drag-resize and preset switch automatically."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries)))
    (etaf-value (etaf-pip--entry-bounds-ref entry))))

;;;###autoload
(defun etaf-pip-frame (id)
  "Return the floating child frame of Picture-in-Picture window ID, or nil."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries))
              (fr (etaf-pip--entry-frame entry)))
    (and (frame-live-p fr) fr)))

;;;###autoload
(defun etaf-pip-buffer (id)
  "Return the mounted buffer of Picture-in-Picture window ID, or nil."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries))
              (buf (etaf-pip--entry-buffer entry)))
    (and (buffer-live-p buf) buf)))

;;;###autoload
(defun etaf-pip-cycle-size (id)
  "Cycle Picture-in-Picture window ID among `small', `medium' and `large'."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries)))
    (let* ((order '(small medium large))
           (next (or (cadr (memq (etaf-pip--entry-size-key entry) order)) 'small))
           (geo nil))
      (setf (etaf-pip--entry-size-key entry) next
            (etaf-pip--entry-last-body-px entry) nil)
      (setq geo (etaf-pip--preset-geometry entry))
      (if-let* ((fr (etaf-pip--entry-frame entry))
                ((frame-live-p fr)))
          (progn
            (let ((etaf-pip--syncing t)
                  (frame-resize-pixelwise t))
              (set-frame-size fr (plist-get geo :frame-px-w)
                              (plist-get geo :frame-px-h) t)
              (set-frame-position fr (plist-get geo :left) (plist-get geo :top)))
            (etaf-pip--sync-bounds entry t))
        (etaf-set-value
         (etaf-pip--entry-bounds-ref entry)
         (list :width-px (plist-get geo :width-px)
               :height-px (plist-get geo :height-px)
               :cols (plist-get geo :cols)
               :rows (plist-get geo :rows)
               :cell-w (plist-get geo :cell-w)
               :cell-h (plist-get geo :cell-h)
               :size next
               :corner (etaf-pip--entry-corner entry)))
        (etaf-pip-refresh-chrome id))
      (when-let* ((cb (etaf-pip--entry-size-change-fn entry)))
        (ignore-errors (funcall cb next)))
      next)))

;;;###autoload
(defun etaf-pip-cycle-corner (id)
  "Dock Picture-in-Picture window ID clockwise to the next frame corner."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries)))
    (let* ((next (or (cadr (memq (etaf-pip--entry-corner entry) etaf-pip--corners))
                     (car etaf-pip--corners))))
      (setf (etaf-pip--entry-corner entry) next)
      (when-let* ((cur (etaf-value (etaf-pip--entry-bounds-ref entry))))
        (etaf-set-value (etaf-pip--entry-bounds-ref entry)
                        (plist-put (copy-sequence cur) :corner next)))
      (etaf-pip--reposition entry)
      (etaf-pip-refresh-chrome id)
      (when-let* ((cb (etaf-pip--entry-corner-change-fn entry)))
        (ignore-errors (funcall cb next)))
      next)))

;;;###autoload
(defun etaf-pip-refresh-chrome (id)
  "Repaint Picture-in-Picture window ID's surface, border and header bar."
  (etaf-pip--validate-id id)
  (when-let* ((entry (gethash id etaf-pip--entries))
              (buf (etaf-pip--entry-buffer entry))
              ((buffer-live-p buf)))
    (let* ((colors (etaf-pip--theme-colors entry))
           (bg (plist-get colors :panel))
           (fg (plist-get colors :ink)))
      (when-let* ((fr (etaf-pip--entry-frame entry))
                  ((frame-live-p fr)))
        (modify-frame-parameters fr `((background-color . ,bg)
                                      (foreground-color . ,fg)))
        (etaf-pip--paint-border entry))
      (with-current-buffer buf
        (face-remap-set-base 'default (list :background (plist-get colors :stage)
                                            :foreground fg))
        (face-remap-set-base 'header-line (list :background bg :foreground fg
                                                :box nil :inherit nil))
        (setq-local header-line-format (etaf-pip--header-format entry))))
    t))

(provide 'etaf-pip)
;;; etaf-pip.el ends here
