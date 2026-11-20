;;; etaf-posframe-tests.el --- Public panel behaviour -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour of `etaf-posframe'.  Cases that need a child frame are
;; skipped in batch Emacs and run in a graphical verification instance.

;;; Code:

;;; Frame measurements

;; Frame measurements and `set-frame-size' accept a frame, never a window.
;; A window argument signals `Wrong type argument: framep, #<window N>'
;; without naming the call site, so the backtrace rarely helps.  Reach a
;; frame with `(window-frame window)' or, for these panels, with the
;; `etaf-posframe-test--window' helper in this file.

(require 'ert)
(require 'seq)
(require 'etaf-posframe)

(ert-deftest etaf-posframe-rejects-invalid-options ()
  "Reject bad options with a message that names the option."
  (let ((view (etaf-view (text "panel"))))
    (should (string-match-p
             "bogus"
             (error-message-string
              (should-error (etaf-posframe-show view :bogus 1)
                            :type 'etaf-posframe-error))))
    (should (string-match-p
             "width"
             (error-message-string
              (should-error (etaf-posframe-show view :width 0)
                            :type 'etaf-posframe-error))))
    (should (string-match-p
             "auto-hide"
             (error-message-string
              (should-error (etaf-posframe-show view :auto-hide 'never)
                            :type 'etaf-posframe-error))))
    (should (string-match-p
             ":at"
             (error-message-string
              (should-error (etaf-posframe-show view :at 'nowhere)
                            :type 'etaf-posframe-error))))
    (should (string-match-p
             "theme"
             (error-message-string
              (should-error (etaf-posframe-show view :theme 'sepia)
                            :type 'etaf-posframe-error))))
    (should (string-match-p
             "resizable"
             (error-message-string
              (should-error (etaf-posframe-show view :resizable 'sideways)
                            :type 'etaf-posframe-error))))
    (should (string-match-p
             "resizable"
             (error-message-string
              (should-error (etaf-posframe-show view :resizable '(left middle))
                            :type 'etaf-posframe-error))))))

(ert-deftest etaf-posframe-theme-returns-frame-colors ()
  "Derive a complete Theme plist with hex colors from the frame."
  (let ((theme (etaf-posframe-theme)))
    (dolist (key '(:ui-panel-bg :ui-panel-fg :ui-border :ui-muted-fg
                   :ui-accent :ui-info-bg :ui-danger-fg))
      (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'"
                              (plist-get theme key))))))

(ert-deftest etaf-posframe-live-p-rejects-non-panels ()
  "Only a live panel counts as live."
  (should-not (etaf-posframe-live-p nil))
  (should-not (etaf-posframe-live-p 'not-a-panel))
  (should-not (etaf-posframe-panels)))

(ert-deftest etaf-posframe-show-owns-panel-lifecycle ()
  "Show mounts one panel and hide releases it."
  (skip-unless (display-graphic-p))
  (let* ((view (etaf-view (text "panel")))
         (panel (etaf-posframe-show view :width 24 :height 4)))
    (should (etaf-posframe-live-p panel))
    (should (= 1 (length (etaf-posframe-panels))))
    (should (etaf-posframe-hide panel))
    (should-not (etaf-posframe-live-p panel))
    (should-not (etaf-posframe-panels))))

(ert-deftest etaf-posframe-toggle-hides-the-open-panel ()
  "Toggle hides the current buffer's panel and reports nil."
  (skip-unless (display-graphic-p))
  (let* ((view (etaf-view (text "panel")))
         (panel (etaf-posframe-toggle view :width 24 :height 4)))
    (unwind-protect
        (progn
          (should (etaf-posframe-live-p panel))
          (should-not (etaf-posframe-toggle view :width 24 :height 4))
          (should-not (etaf-posframe-panels)))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-show-replaces-the-buffer-panel ()
  "A second show for the same buffer replaces its panel."
  (skip-unless (display-graphic-p))
  (let* ((view (etaf-view (text "panel")))
         (first (etaf-posframe-show view :width 24 :height 3)))
    (unwind-protect
        (progn
          (should (= 1 (length (etaf-posframe-panels))))
          (let ((second (etaf-posframe-show view :width 24 :height 3)))
            (should (= 1 (length (etaf-posframe-panels))))
            (should-not (etaf-posframe-live-p first))
            (should (etaf-posframe-live-p second))))
      (mapc #'etaf-posframe-hide (etaf-posframe-panels)))))

(defun etaf-posframe-test--settle (seconds)
  "Let the panel render and finish its deferred fit for SECONDS."
  (sit-for seconds)
  (sit-for seconds))

(defun etaf-posframe-test--window (panel)
  "Return PANEL's frame window, or nil when the panel is not live."
  (let ((frame (etaf-posframe-panel-frame panel)))
    (and (window-live-p (and frame (frame-root-window frame)))
         (frame-root-window frame))))

(defun etaf-posframe-test--frame-size (panel)
  "Return PANEL's frame as (ROWS COLUMNS), title row included."
  (let* ((frame (etaf-posframe-panel-frame panel))
         (char-h (frame-char-height frame))
         (char-w (frame-char-width frame)))
    (cons (round (/ (frame-pixel-height frame) (float char-h)))
          (round (/ (frame-pixel-width frame) (float char-w))))))

(etaf-define-component etaf-posframe-test--surface-app (&key session)
  "Declare SESSION's palette and mode on the host surface, like a real app."
  :bindings ((palette (plist-get session :palette))
             (mode (plist-get session :mode)))
  :setup (when-let* ((surface (etaf-surface-host)))
           (etaf-surface-declare surface
                                 :theme palette
                                 :mode mode
                                 :modes '((light . "亮") (auto . "随") (dark . "暗"))))
  :render (etaf-view (text (expr (format "app:%s" (etaf-value mode))))))

(defun etaf-posframe-test--surface-session ()
  "Return a session for an application that owns its palette and mode."
  (list :palette (etaf-ref (etaf-posframe-theme nil 'dark))
        :mode (etaf-ref 'auto)))

(ert-deftest etaf-posframe-pinned-theme-reaches-the-content ()
  "A pinned `:theme' starts the content in that mode, once.
A panel whose content owns its palette used to paint a light title bar over a
content that stayed in its own dark default, because the pin never reached the
content's mode cell."
  (skip-unless (display-graphic-p))
  (let* ((session (etaf-posframe-test--surface-session))
         (mode (plist-get session :mode))
         (palette (plist-get session :palette))
         (panel (etaf-posframe-show
                 (etaf-view (etaf-posframe-test--surface-app :session session))
                 :key 'pinned-light :width 24 :height 6 :theme 'light
                 :at 'frame-top-right)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.3)
          (should (eq 'light (etaf-value mode)))
          ;; The content's own switch afterwards is authoritative: a later
          ;; surface pass must not push the pin back over the user's choice.
          (etaf-set-value mode 'dark)
          (etaf-posframe-test--settle 0.2)
          (etaf-set-value palette (append (etaf-value palette) '(:ui-note test)))
          (etaf-posframe-test--settle 0.3)
          (should (eq 'dark (etaf-value mode))))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel))))
  ;; An `auto' panel leaves the content's mode alone.
  (let* ((session (etaf-posframe-test--surface-session))
         (mode (plist-get session :mode))
         (panel (etaf-posframe-show
                 (etaf-view (etaf-posframe-test--surface-app :session session))
                 :key 'pin-auto :width 24 :height 6 :theme 'auto
                 :at 'frame-top-right)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.3)
          (should (eq 'auto (etaf-value mode))))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel)))))

(ert-deftest etaf-posframe-resize-follows-an-outside-resize-by-default ()
  "A panel adopts a frame resized from outside, which is the default."
  (skip-unless (display-graphic-p))
  (let* ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'resize-default :width 24 :height 8
                                    :at 'frame-top-right))
         (window nil)
         (body nil))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (setq window (etaf-posframe-test--window panel)
                body (window-body-width window t))
          (set-frame-size (etaf-posframe-panel-frame panel)
                          (+ body (* 10 (frame-char-width (window-frame window))))
                          (window-pixel-height window) t)
          (etaf-posframe-test--settle 0.25)
          (should (>= (- (window-body-width
                          (etaf-posframe-test--window panel) t)
                         body)
                      (* 9 (frame-char-width (window-frame window))))))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel)))))

(ert-deftest etaf-posframe-resizable-nil-refuses-an-outside-resize ()
  "`:resizable nil' puts the frame back after an outside resize."
  (skip-unless (display-graphic-p))
  (let* ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'resize-none :width 24 :height 8
                                    :resizable nil :at 'frame-top-right))
         (window nil)
         (body nil)
         (rows nil)
         (origin nil))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (setq window (etaf-posframe-test--window panel)
                body (window-body-width window t)
                rows (window-pixel-height window))
          (set-frame-size (etaf-posframe-panel-frame panel)
                          (+ body (* 10 (frame-char-width (window-frame window))))
                          (+ rows (* 3 (frame-char-height (window-frame window)))) t)
          (etaf-posframe-test--settle 0.3)
          (let ((settled (etaf-posframe-test--window panel)))
            (should (= body (window-body-width settled t)))
            (should (= rows (window-pixel-height settled))))
          ;; A top or left edge drag moves the frame origin with the size, so
          ;; a refused resize must put the panel back where it was as well.
          (setq origin (frame-position (etaf-posframe-panel-frame panel)))
          (set-frame-position (etaf-posframe-panel-frame panel)
                              (+ (car origin)
                                 (* 2 (frame-char-width (window-frame window))))
                              (+ (cdr origin)
                                 (* 2 (frame-char-height (window-frame window)))))
          (set-frame-size (etaf-posframe-panel-frame panel)
                          (- body (* 4 (frame-char-width (window-frame window))))
                          (- rows (* 2 (frame-char-height (window-frame window)))) t)
          (etaf-posframe-test--settle 0.3)
          (let ((settled (etaf-posframe-test--window panel)))
            (should (= body (window-body-width settled t)))
            (should (= rows (window-pixel-height settled)))
            (should (equal origin
                           (frame-position (etaf-posframe-panel-frame panel))))))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel)))))

(ert-deftest etaf-posframe-a-narrower-frame-clips-instead-of-wrapping ()
  "A frame made narrower clips the canvas rows instead of wrapping them.
Posframe writes `truncate-lines' from its own keyword, so a panel that does not
ask for truncation wraps its old, wider rows as soon as a drag narrows the
frame, and a board scrambles until the fit catches up."
  (skip-unless (display-graphic-p))
  (let* ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'clip :width 24 :height 8
                                    :at 'frame-top-right))
         (window nil)
         (buffer nil))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (setq window (etaf-posframe-test--window panel)
                buffer (window-buffer window))
          (should (buffer-local-value 'truncate-lines buffer))
          ;; A drag narrows the frame before the View re-lays out, so the
          ;; frame shows wider rows than it can hold for one moment.
          (set-frame-size (window-frame window)
                          (- (window-body-width window t)
                             (* 8 (frame-char-width (window-frame window))))
                          (window-pixel-height window) t)
          (should (buffer-local-value 'truncate-lines buffer))
          (etaf-posframe-test--settle 0.3))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel)))))

(ert-deftest etaf-posframe-resizable-list-limits-the-axes ()
  "A side list allows the axes it names and restores the others."
  (skip-unless (display-graphic-p))
  (let* ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'resize-width :width 24 :height 8
                                    :fill-height t
                                    :resizable '(right) :at 'frame-top-right))
         (window nil)
         (body nil)
         (rows nil))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (setq window (etaf-posframe-test--window panel)
                body (window-body-width window t)
                rows (window-pixel-height window))
          ;; a height change is refused: `top' and `bottom' are not listed
          (set-frame-size (window-frame window) body
                          (+ rows (* 12 (frame-char-height (window-frame window))))
                          t)
          (etaf-posframe-test--settle 0.3)
          (should (= rows (window-pixel-height
                           (etaf-posframe-test--window panel))))
          ;; a width change is accepted: `right' is listed
          (set-frame-size (window-frame window)
                          (+ body (* 10 (frame-char-width (window-frame window))))
                          rows t)
          (etaf-posframe-test--settle 0.3)
          (should (>= (window-body-width
                       (etaf-posframe-test--window panel) t)
                      (+ body (* 9 (frame-char-width (window-frame window)))))))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel))))
  (let* ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'resize-height :width 24 :height 8
                                    :fill-height t
                                    :resizable '(top bottom) :at 'frame-top-right))
         (window nil)
         (body nil)
         (rows nil))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (setq window (etaf-posframe-test--window panel)
                body (window-body-width window t)
                rows (window-pixel-height window))
          ;; a width change is refused: neither `left' nor `right' is listed
          (set-frame-size (window-frame window)
                          (+ body (* 10 (frame-char-width (window-frame window))))
                          rows t)
          (etaf-posframe-test--settle 0.3)
          (should (= body (window-body-width
                           (etaf-posframe-test--window panel)
                           t)))
          ;; a height change past the row budget is accepted
          (set-frame-size (window-frame window) body
                          (+ rows (* 12 (frame-char-height (window-frame window))))
                          t)
          (etaf-posframe-test--settle 0.3)
          (should (>= (window-pixel-height
                       (etaf-posframe-test--window panel))
                      (+ rows (* 9 (frame-char-height (window-frame window)))))))
      (when (etaf-posframe-live-p panel) (etaf-posframe-hide panel)))))

(ert-deftest etaf-posframe-timeout-closes-the-panel ()
  "A panel with :auto-hide seconds hides by itself."
  (skip-unless (display-graphic-p))
  (let* ((view (etaf-view (text "panel")))
         (panel (etaf-posframe-show view :width 24 :height 3 :auto-hide 0.2))
         (deadline (+ (float-time) 3)))
    (should (etaf-posframe-live-p panel))
    ;; Poll instead of sleeping a fixed span: a busy session runs the hide
    ;; timer late, and the panel still has to close.
    (while (and (etaf-posframe-live-p panel) (< (float-time) deadline))
      (sleep-for 0.05))
    (should-not (etaf-posframe-live-p panel))
    (should-not (etaf-posframe-panels))))

(ert-deftest etaf-posframe-focusable-panel-takes-and-restores-focus ()
  "A focusable panel is selected on open and restores the previous frame."
  (skip-unless (display-graphic-p))
  (let* ((view (etaf-view (text "panel")))
         (origin (selected-frame))
         (panel (etaf-posframe-show view :width 24 :height 3 :focusable t)))
    (unwind-protect
        (progn
          (should (etaf-posframe-live-p panel))
          (should-not (eq (selected-frame) origin))
          (should (frame-parent (selected-frame))))
      (etaf-posframe-hide panel))
    (should (eq (selected-frame) origin))))

(ert-deftest etaf-posframe-killing-the-parent-buffer-closes-the-panel ()
  "Killing the buffer that owns a panel hides that panel."
  (skip-unless (display-graphic-p))
  (let ((buffer (generate-new-buffer " *etaf-posframe-test-parent*")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                           :width 24 :height 3)))
            (should (etaf-posframe-live-p panel))
            (kill-buffer buffer)
            (should-not (etaf-posframe-live-p panel))
            (should-not (etaf-posframe-panels))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun etaf-posframe-tests--panel-frame (parent)
  "Return the single child frame of PARENT that shows a panel."
  (let ((frames (seq-filter (lambda (frame) (eq (frame-parent frame) parent))
                            (frame-list))))
    (should (= 1 (length frames)))
    (car frames)))

(defun etaf-posframe-tests--top-frame ()
  "Return a top level frame, whatever the previous case left selected."
  (or (seq-find (lambda (frame) (null (frame-parent frame))) (frame-list))
      (selected-frame)))

(defun etaf-posframe-tests--placement (parent columns lines &rest options)
  "Show a COLUMNS x LINES panel with OPTIONS in PARENT.
Return a plist with the frame `:at' offset and its `:size'; the frame shrinks to
its content, so its height is not the requested line count."
  (let ((panel (apply #'etaf-posframe-show (etaf-view (text "x"))
                      :width columns :height lines options)))
    (unwind-protect
        (let ((frame (etaf-posframe-tests--panel-frame parent)))
          (list :at (cons (frame-parameter frame 'left)
                          (frame-parameter frame 'top))
                :size (cons (frame-pixel-width frame)
                            (frame-pixel-height frame))))
      (etaf-posframe-hide panel))))

(defun etaf-posframe-tests--panel-window (frame)
  "Return the window FRAME shows its panel in."
  (frame-root-window frame))

(defun etaf-posframe-tests--panel-buffer (frame)
  "Return the buffer FRAME displays."
  (window-buffer (etaf-posframe-tests--panel-window frame)))

(defun etaf-posframe-tests--with-pointer-on (frame function)
  "Call FUNCTION with the window system reporting the pointer on FRAME.
A child frame cannot be pointed at from Lisp, so the position query the panel
follows is answered instead."
  (cl-letf (((symbol-function 'mouse-pixel-position)
             (lambda () (list frame 5 5))))
    (funcall function)))

(defun etaf-posframe-tests--luminance (color)
  "Return the relative luminance of COLOR."
  (apply #'+ (cl-mapcar (lambda (weight channel) (* weight channel))
                        '(0.2126 0.7152 0.0722)
                        (color-name-to-rgb color))))

(defun etaf-posframe-tests--mix (from to amount)
  "Mix hex colors FROM and TO by AMOUNT toward TO."
  (let ((start (color-name-to-rgb from))
        (end (color-name-to-rgb to)))
    (apply #'color-rgb-to-hex
           (append (cl-mapcar (lambda (a b) (+ a (* (- b a) amount)))
                              start end)
                   '(2)))))

(ert-deftest etaf-posframe-frame-is-as-wide-as-the-canvas ()
  "A panel frame is exactly as wide as its content columns.
The frame used to keep whatever width posframe gave it, so a font metric
mismatch left empty frame to the right of the canvas."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (char (frame-char-width parent))
         (columns (max 20 (- (/ (frame-pixel-width parent) char) 8)))
         (panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :width columns)))
    (unwind-protect
        (let* ((frame (etaf-posframe-tests--panel-frame parent))
               (window (etaf-posframe-tests--panel-window frame)))
          ;; The border is painted outside the text area, so the visible
          ;; content keeps exactly the panel's column width.
          (should (= (* columns char) (window-body-width window t)))
          (should (= (frame-text-width frame) (window-body-width window t)))
          (should (= columns (window-body-width window))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-frame-is-not-taller-than-the-content ()
  "A one-line panel fits its frame instead of leaving empty rows below."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (line (frame-char-height parent))
         (panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :width 24 :height 6)))
    (unwind-protect
        (let* ((frame (etaf-posframe-tests--panel-frame parent))
               (window (etaf-posframe-tests--panel-window frame))
               (height (frame-pixel-height frame)))
          (should (<= height (* 2 line)))
          (should (<= (cdr (window-text-pixel-size window (point-min) (point-max)
                                                   nil nil t))
                      height)))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-header-bar-paints-the-full-width ()
  "The title bar covers every column, keeps the panel's palette and owns its outline.
A light theme's `header-line' box would draw a dark outline around the bar, so
the bar clears the box and keeps one hairline of its own."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (palette (etaf-posframe-theme parent))
         (panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :width 24 :title "ETAF")))
    (unwind-protect
        (let* ((frame (etaf-posframe-tests--panel-frame parent))
               (header (with-current-buffer (etaf-posframe-tests--panel-buffer frame)
                         header-line-format))
               (face (get-text-property 0 'face header))
               (surface (etaf-posframe-tests--mix
                         (plist-get palette :ui-panel-bg)
                         (plist-get palette :ui-panel-fg) 0.03)))
          (should (= 24 (string-width header)))
          (should (eq t (plist-get face :extend)))
          (should (memq :inverse-video face))
          (should-not (plist-get face :inverse-video))
          ;; The bar answers for its own outline, not the theme's.
          (should (memq :box face))
          (should-not (plist-get face :box))
          (should (equal surface (plist-get face :background)))
          (should (equal (plist-get palette :ui-panel-border)
                         (plist-get (get-text-property 0 'underline header)
                                    :color))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-frame-follows-an-outside-resize ()
  "A frame resized from outside becomes the panel width, canvas included."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (char (frame-char-width parent))
         (columns (max 20 (- (/ (frame-pixel-width parent) char) 40)))
         (panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :width columns :title "ETAF")))
    (unwind-protect
        (let* ((frame (etaf-posframe-tests--panel-frame parent))
               (window (etaf-posframe-tests--panel-window frame))
               (buffer (etaf-posframe-tests--panel-buffer frame))
               (width (+ (* columns char) (* 10 char))))
          (set-frame-size frame width 400 t)
          ;; The resize is reported by the next redisplay, which then defers
          ;; the re-layout out of its own callback.
          (redisplay t)
          (sleep-for 0.4)
          (should (= width (window-body-width window t)))
          (should (= width (car (etaf-runtime-viewport
                                 (etaf-runtime-for-buffer buffer)))))
          (should (= (/ width char)
                     (string-width (with-current-buffer buffer
                                     header-line-format))))
          ;; A later fit keeps the adopted width instead of snapping back.
          (etaf-posframe-refresh panel)
          (sleep-for 0.3)
          (should (= width (window-body-width window t))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-frame-adopts-a-shorter-height ()
  "A frame shortened below the content becomes the new row budget."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (line (frame-char-height parent))
         (char (frame-char-width parent))
         (panel (etaf-posframe-show
                 (etaf-view (column :item-gap '(lh 0)
                                    (text "r1") (text "r2") (text "r3")
                                    (text "r4") (text "r5") (text "r6")))
                 :width 24 :height 6)))
    (unwind-protect
        (let* ((frame (etaf-posframe-tests--panel-frame parent))
               (window (etaf-posframe-tests--panel-window frame)))
          (should (<= 6 (window-body-height window)))
          (set-frame-size frame (* 24 char) (* 3 line) t)
          (redisplay t)
          (sleep-for 0.4)
          (should (= 3 (window-body-height window))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-panel-prints-without-recursing ()
  "Printing a panel finishes, so evaluating a show call cannot hang Emacs.
`C-x C-e' prints the returned panel into the buffer; a Runtime or Theme ref
slot made that print follow a cycle until Emacs ran out of memory."
  (skip-unless (display-graphic-p))
  (let ((panel (etaf-posframe-show (etaf-view (text "panel"))
                                   :width 20 :height 2)))
    (unwind-protect
        (let ((text (with-timeout (2 :print-did-not-finish)
                      (let ((print-circle nil)
                            (print-level nil)
                            (print-length nil))
                        (prin1-to-string panel)))))
          (should (stringp text))
          (should (string-match-p "etaf-posframe--panel" text)))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-panels-coexist-by-key ()
  "Panels with different keys stay open together and hide independently."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (first (etaf-posframe-show (etaf-view (text "first")) :key 'first
                                    :width 24 :height 2))
         (second (etaf-posframe-show (etaf-view (text "second")) :key 'second
                                     :width 24 :height 2)))
    (unwind-protect
        (progn
          (should (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p second))
          (should (= 2 (length (etaf-posframe-panels))))
          (should (= 2 (length (seq-filter (lambda (frame) (frame-parent frame))
                                          (frame-list)))))
          (should (etaf-posframe-hide first))
          (should-not (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p second))
          (should (= 1 (length (etaf-posframe-panels)))))
      (ignore-errors (etaf-posframe-hide second))
      (ignore-errors (etaf-posframe-hide first))
      (ignore-errors (etaf-posframe-tests--panel-frame parent)))))

(ert-deftest etaf-posframe-show-replaces-the-same-key ()
  "A second show with the same key replaces that panel and nothing else."
  (skip-unless (display-graphic-p))
  (let* ((first (etaf-posframe-show (etaf-view (text "first")) :key 'same
                                    :width 24 :height 2))
         (other (etaf-posframe-show (etaf-view (text "other")) :key 'other
                                    :width 24 :height 2))
         (replacement (etaf-posframe-show (etaf-view (text "third")) :key 'same
                                          :width 24 :height 2)))
    (unwind-protect
        (progn
          (should-not (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p replacement))
          (should (etaf-posframe-live-p other))
          (should (= 2 (length (etaf-posframe-panels)))))
      (ignore-errors (etaf-posframe-hide replacement))
      (ignore-errors (etaf-posframe-hide other)))))

(ert-deftest etaf-posframe-toggle-targets-its-key ()
  "Toggle hides the panel of its own key and leaves the others open."
  (skip-unless (display-graphic-p))
  (let* ((first (etaf-posframe-show (etaf-view (text "first")) :key 'first
                                    :width 24 :height 2))
         (second (etaf-posframe-show (etaf-view (text "second")) :key 'second
                                     :width 24 :height 2)))
    (unwind-protect
        (progn
          (should-not (etaf-posframe-toggle (etaf-view (text "first")) :key 'first
                                            :width 24 :height 2))
          (should-not (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p second)))
      (ignore-errors (etaf-posframe-hide second)))))

(ert-deftest etaf-posframe-anchors-place-panels-in-the-grid ()
  "Frame and window anchors put a panel at the expected place.
Each assertion uses the size of the frame it just measured, because a panel is
sized from its content."
  (skip-unless (display-graphic-p))
  (let* ((parent (etaf-posframe-tests--top-frame))
         (frame-width (frame-pixel-width parent))
         (frame-height (frame-pixel-height parent))
         (edges (window-inside-pixel-edges (selected-window)))
         ;; One character cell against a frame edge, half a cell against a
         ;; window's text area; a terminal reports one pixel per cell.
         (margin (frame-char-width parent))
         (window-margin (max 1 (/ margin 2))))
    (cl-labels ((place (anchor)
                  (etaf-posframe-tests--placement parent 20 2 :at anchor))
                (at-of (anchor) (plist-get (place anchor) :at))
                (size-of (anchor) (plist-get (place anchor) :size)))
      (should (equal (at-of 'frame-top-left) (cons 0 margin)))
      (let ((size (size-of 'frame-top-left)))
        (should (equal (at-of 'frame-top-right)
                       (cons (- frame-width (car size) margin) margin))))
      (let ((size (size-of 'frame-bottom-left)))
        (should (equal (at-of 'frame-bottom-left)
                       (cons 0 (- frame-height (cdr size) margin)))))
      (let ((size (size-of 'frame-bottom-right)))
        (should (equal (at-of 'frame-bottom-right)
                       (cons (- frame-width (car size) margin)
                             (- frame-height (cdr size) margin)))))
      (let ((size (size-of 'frame-center)))
        (should (equal (at-of 'frame-center)
                       (cons (/ (- frame-width (car size)) 2)
                             (/ (- frame-height (cdr size)) 2)))))
      (should (equal (at-of 'window-top-left)
                     (cons (nth 0 edges) (+ (nth 1 edges) window-margin))))
      (let ((size (size-of 'window-bottom-right)))
        (should (equal (at-of 'window-bottom-right)
                       (cons (- (nth 2 edges) (car size) window-margin)
                             (- (nth 3 edges) (cdr size) window-margin))))))))

(ert-deftest etaf-posframe-cell-places-a-panel-at-character-cells ()
  "An :at (cells ...) placement lands on the same cell whatever the panel size."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (edges (window-inside-pixel-edges (selected-window)))
         (char-width (frame-char-width parent))
         (char-height (frame-char-height parent))
         (origin (cons (nth 0 edges) (nth 1 edges))))
    (should (equal (plist-get (etaf-posframe-tests--placement
                               parent 20 2 :at '(cells 0 0))
                              :at)
                   origin))
    (should (equal (plist-get (etaf-posframe-tests--placement
                               parent 30 4 :at '(cells 0 0))
                              :at)
                   origin))
    (should (equal (plist-get (etaf-posframe-tests--placement
                               parent 20 2 :at '(cells 3 5))
                              :at)
                   (cons (+ (car origin) (* 5 char-width))
                         (+ (cdr origin) (* 3 char-height)))))))

(ert-deftest etaf-posframe-rejects-a-bad-placement ()
  "A placement that is not an anchor, a tagged pair or a function is rejected."
  (let ((view (etaf-view (text "x"))))
    (dolist (value '((-1 . 2) (1.5 . 2) 3 ("a" . 1) (cells "a" 1)))
      (should (string-match-p
               ":at"
               (error-message-string
                (should-error (etaf-posframe-show view :at value)
                              :type 'etaf-posframe-error)))))))

(ert-deftest etaf-posframe-panel-opened-in-a-panel-is-independent ()
  "A panel opened while another panel has focus outlives that panel."
  (skip-unless (display-graphic-p))
  (let* ((buffer (get-buffer-create " *etaf-posframe-test-owner*"))
         (first nil)
         (second nil))
    (unwind-protect
        (with-current-buffer buffer
          (setq first (etaf-posframe-show (etaf-view (text "first"))
                                          :key 'first :width 24 :height 2
                                          :focusable t))
          ;; The first panel is focused now, so its buffer is current: the
          ;; second panel would otherwise belong to it and die with it.
          (setq second (etaf-posframe-show (etaf-view (text "second"))
                                           :key 'second :width 24 :height 2))
          (should (= 2 (length (etaf-posframe-panels))))
          (etaf-posframe-hide first)
          (should-not (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p second))
          (kill-buffer buffer)
          (should-not (etaf-posframe-live-p second))
          (should-not (etaf-posframe-panels)))
      (ignore-errors (etaf-posframe-hide second))
      (ignore-errors (etaf-posframe-hide first))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-posframe-hiding-a-focused-panel-returns-focus ()
  "Hiding a focused panel selects the frame it came from, and the next show works.
`select-frame' alone leaves the window system without a key window, so the
command after a close used to freeze."
  (skip-unless (display-graphic-p))
  (let* ((view (etaf-view (text "panel")))
         (origin (selected-frame))
         (panel (etaf-posframe-show view :width 24 :height 3 :focusable t)))
    (unwind-protect
        (progn
          (should-not (eq (selected-frame) origin))
          (should (etaf-posframe-hide panel))
          (should (eq (selected-frame) origin))
          (should (window-live-p (selected-window)))
          (let ((again (with-timeout (5 (error "opening a panel again hung"))
                         (etaf-posframe-show view :width 24 :height 3))))
            (should (etaf-posframe-live-p again))
            (etaf-posframe-hide again)))
      (ignore-errors (etaf-posframe-hide panel)))))

(ert-deftest etaf-posframe-stacks-panels-at-the-same-anchor ()
  "Panels opened at one anchored place are laid out one below the other."
  (skip-unless (display-graphic-p))
  (let* ((first (etaf-posframe-show (etaf-view (text "first")) :key 'first
                                    :at 'frame-top-right :stack t
                                    :width 24 :height 3))
         (second (etaf-posframe-show (etaf-view (text "second")) :key 'second
                                     :at 'frame-top-right :stack t
                                     :width 24 :height 3))
         (third (etaf-posframe-show (etaf-view (text "third")) :key 'third
                                    :at 'frame-top-right :stack t
                                    :width 24 :height 3)))
    (unwind-protect
        (let ((y1 (frame-parameter (etaf-posframe-panel-frame first) 'top))
              (y2 (frame-parameter (etaf-posframe-panel-frame second) 'top))
              (y3 (frame-parameter (etaf-posframe-panel-frame third) 'top))
              (height (frame-pixel-height (etaf-posframe-panel-frame first)))
              (x1 (frame-parameter (etaf-posframe-panel-frame first) 'left))
              (x3 (frame-parameter (etaf-posframe-panel-frame third) 'left)))
          (should (= x1 x3))
          ;; Stacked downward, evenly, without overlapping.
          (should (< y1 y2 y3))
          (should (>= (- y2 y1) height))
          (should (= (- y2 y1) (- y3 y2))))
      (ignore-errors (etaf-posframe-hide third))
      (ignore-errors (etaf-posframe-hide second))
      (ignore-errors (etaf-posframe-hide first)))))

(ert-deftest etaf-posframe-stacks-a-tall-panel-against-a-short-one ()
  "A panel with more content takes the next row instead of its own height.
The stack stepped by the height of the panel being shown, so a panel taller
than the one above it opened a hole as tall as the difference."
  (skip-unless (display-graphic-p))
  (let* ((rows (lambda (count)
                 (etaf-view (column :item-gap '(lh 0)
                                    (expr (mapcar (lambda (i) (format "row %d" i))
                                                  (number-sequence 1 count)))))))
         (short (etaf-posframe-show (funcall rows 2) :key 'stack-short
                                    :at 'frame-top-right :stack t
                                    :width 20 :height 10 :title "short"))
         (tall (etaf-posframe-show (funcall rows 8) :key 'stack-tall
                                   :at 'frame-top-right :stack t
                                   :width 20 :height 10 :title "tall")))
    (unwind-protect
        (let* ((first (etaf-posframe-panel-frame short))
               (second (etaf-posframe-panel-frame tall))
               (bottom (+ (frame-parameter first 'top) (frame-pixel-height first)))
               (gap (- (frame-parameter second 'top) bottom)))
          ;; Both right edges land on the anchor and the two frames touch.
          (should (= (frame-parameter first 'left)
                     (frame-parameter second 'left)))
          (should (>= gap 0))
          (should (< gap (frame-char-height first))))
      (ignore-errors (etaf-posframe-hide tall))
      (ignore-errors (etaf-posframe-hide short)))))

(ert-deftest etaf-posframe-draws-a-theme-bordered-panel ()
  "A panel carries a border in the given colour without losing content width."
  (skip-unless (display-graphic-p))
  (let* ((parent (selected-frame))
         (char (frame-char-width parent))
         (panel (etaf-posframe-show (etaf-view (text "x"))
                                    :width 24 :height 2
                                    :border '(:width 2 :color "#123456"))))
    (unwind-protect
        (let ((frame (etaf-posframe-tests--panel-frame parent)))
          (should (= 2 (frame-parameter frame 'child-frame-border-width)))
          (should (= (* 24 char) (window-body-width
                                  (etaf-posframe-tests--panel-window frame) t)))
          (should (equal "#123456"
                         (face-attribute 'child-frame-border :background frame))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-rejects-stack-without-an-anchor ()
  ":stack needs an anchored place, not a cell or a pixel pair."
  (let ((view (etaf-view (text "x"))))
    (dolist (options '((:stack t :at (cells 0 0))
                       (:stack t :at (pixels 10 . 10))))
      (should (string-match-p
               "stack"
               (error-message-string
                (should-error (apply #'etaf-posframe-show view options)
                              :type 'etaf-posframe-error)))))))

(ert-deftest etaf-posframe-registered-apps-open-with-one-call ()
  "A registered application opens and closes with one call, next to others."
  (skip-unless (display-graphic-p))
  (let ((saved-apps etaf-posframe-apps)
        (saved-map etaf-posframe-app-map)
        (first nil)
        (second nil))
    (unwind-protect
        (progn
          (etaf-posframe-register-app 'test-one
                                      :title "One" :shortcut "1"
                                      :create #'ignore
                                      :view (lambda (_session) (etaf-view (text "one")))
                                      :width 20 :height 2)
          (etaf-posframe-register-app 'test-two
                                      :title "Two" :shortcut "2"
                                      :create #'ignore
                                      :view (lambda (_session) (etaf-view (text "two")))
                                      :width 20 :height 2)
          (should (commandp (lookup-key etaf-posframe-app-map "1")))
          (should (commandp (lookup-key etaf-posframe-app-map "2")))
          (setq first (etaf-posframe-app 'test-one)
                second (etaf-posframe-app 'test-two))
          (should (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p second))
          (should-not (eq (etaf-posframe-panel-frame first)
                          (etaf-posframe-panel-frame second)))
          (should-not (etaf-posframe-app 'test-one))
          (should-not (etaf-posframe-live-p first))
          (should (etaf-posframe-live-p second)))
      (ignore-errors (etaf-posframe-hide second))
      (ignore-errors (etaf-posframe-hide first))
      (setq etaf-posframe-apps saved-apps
            etaf-posframe-app-map saved-map))))

(ert-deftest etaf-posframe-cycle-walks-panels-and-back ()
  "Cycling focuses each panel in turn, then returns to the frame behind them."
  (skip-unless (display-graphic-p))
  (let* ((origin (selected-frame))
         (first (etaf-posframe-show (etaf-view (text "first")) :key 'cycle-one
                                    :width 24 :height 2))
         (second (etaf-posframe-show (etaf-view (text "second")) :key 'cycle-two
                                     :width 24 :height 2)))
    (unwind-protect
        (progn
          (etaf-posframe-cycle)
          (should (eq (selected-frame) (etaf-posframe-panel-frame second)))
          (etaf-posframe-cycle)
          (should (eq (selected-frame) (etaf-posframe-panel-frame first)))
          (etaf-posframe-cycle)
          (should (eq (selected-frame) origin)))
      (ignore-errors (etaf-posframe-hide second))
      (ignore-errors (etaf-posframe-hide first))
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-focus-shows-in-the-border ()
  "The focused panel paints its border differently from the resting ones.
The accent follows the selection, so selecting a panel or the frame behind them
switches it without running any panel command."
  (skip-unless (display-graphic-p))
  (let ((origin (etaf-posframe-tests--top-frame)))
    (unless (eq (selected-frame) origin)
      (select-frame origin))
    (let* ((first (etaf-posframe-show (etaf-view (text "first"))
                                      :key 'border-one :width 24 :height 2
                                      :focusable t))
           (second (etaf-posframe-show (etaf-view (text "second"))
                                       :key 'border-two :width 24 :height 2
                                       :focusable t))
           (colour (lambda (panel)
                     (face-attribute 'child-frame-border :background
                                     (etaf-posframe-panel-frame panel)))))
      (unwind-protect
          (progn
            ;; Cycling focuses one panel at a time and its border differs from
            ;; the panel that does not have the focus.
            (dotimes (_ 3)
              (etaf-posframe-cycle)
              (with-timeout (2 nil) (sleep-for 0.1))
              (let ((selected (selected-frame)))
                (when (eq selected (etaf-posframe-panel-frame first))
                  (should-not (equal (funcall colour first)
                                     (funcall colour second))))
                (when (eq selected (etaf-posframe-panel-frame second))
                  (should-not (equal (funcall colour first)
                                     (funcall colour second))))))
            ;; Selecting a frame like a click does, then running a command,
            ;; moves the accent on its own: on the frame behind them both
            ;; panels look the same, on a panel it differs again.
            (select-frame origin)
            (run-hooks 'post-command-hook)
            (should (equal (funcall colour first) (funcall colour second)))
            (let ((resting (funcall colour second)))
              (select-frame (etaf-posframe-panel-frame first))
              (run-hooks 'post-command-hook)
              (should-not (equal resting (funcall colour first)))
              (should (equal resting (funcall colour second)))))
        (ignore-errors (etaf-posframe-hide second))
        (ignore-errors (etaf-posframe-hide first))
        (ignore-errors (select-frame-set-input-focus origin))))))

(ert-deftest etaf-posframe-fill-keeps-the-row-budget ()
  "A panel with :fill-height keeps the row budget although its content is shorter."
  (skip-unless (display-graphic-p))
  (let* ((parent (etaf-posframe-tests--top-frame))
         (rows 12)
         (panel (etaf-posframe-show (etaf-view (text "short"))
                                    :width 24 :height rows :fill-height t)))
    (unwind-protect
        (let* ((frame (etaf-posframe-tests--panel-frame parent))
               (window (etaf-posframe-tests--panel-window frame)))
          (should (>= (window-body-height window) (1- rows)))
          (should (< (* rows (frame-char-height parent))
                     (frame-pixel-height frame))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-height-fits-the-parent-frame ()
  "A row budget larger than the parent frame is clamped to what fits."
  (skip-unless (display-graphic-p))
  (let* ((parent (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "short"))
                                    :width 24 :height 500 :fill-height t)))
    (unwind-protect
        (let ((frame (etaf-posframe-tests--panel-frame parent)))
          (should (<= (frame-pixel-height frame) (frame-pixel-height parent)))
          (should (> (window-body-height (etaf-posframe-tests--panel-window frame))
                     10)))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-anchor-offset-shifts-the-anchor ()
  "An (ANCHOR ROWS COLS) placement moves a panel by character cells."
  (skip-unless (display-graphic-p))
  (let* ((parent (etaf-posframe-tests--top-frame))
         (char-width (frame-char-width parent))
         (char-height (frame-char-height parent))
         (plain (etaf-posframe-tests--placement parent 20 2 :at 'frame-center))
         (origin (plist-get plain :at))
         (shifted (etaf-posframe-tests--placement parent 20 2
                                                  :at '(frame-center 2 -3)))
         (at (plist-get shifted :at)))
    (should (equal at (cons (- (car origin) (* 3 char-width))
                            (+ (cdr origin) (* 2 char-height)))))))

(ert-deftest etaf-posframe-hover-focuses-a-panel ()
  "The pointer on a panel focuses it when asked, and never a passive panel."
  (skip-unless (display-graphic-p))
  ;; The behaviour is opt-in: a resting pointer must not move the keyboard away
  ;; from another window.
  (let* ((etaf-posframe-focus-follows-mouse t)
         (origin (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "hover"))
                                    :key 'hover :width 24 :height 2
                                    :focusable t))
         (frame (etaf-posframe-panel-frame panel)))
    (unwind-protect
        (progn
          (select-frame origin)
          (etaf-posframe-tests--with-pointer-on
           frame (lambda () (run-hooks 'post-command-hook)))
          (should (eq (selected-frame) frame))
          ;; A passive panel never takes the focus from the pointer.
          (etaf-posframe-hide panel)
          (setq panel (etaf-posframe-show (etaf-view (text "passive"))
                                          :key 'hover :width 24 :height 2
                                          :focusable nil)
                frame (etaf-posframe-panel-frame panel))
          (select-frame origin)
          (etaf-posframe-tests--with-pointer-on
           frame (lambda () (run-hooks 'post-command-hook)))
          (should (eq (selected-frame) origin)))
      (ignore-errors (etaf-posframe-hide panel))
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-hides-panels-while-emacs-is-inactive ()
  "Panels become invisible while Emacs is inactive and come back after.
A child frame is a window of its own, and a window manager that lists windows
would offer the panel as a target instead of the application behind it."
  (skip-unless (display-graphic-p))
  (skip-unless etaf-posframe-hide-inactive)
  (let* ((origin (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "inactive"))
                                    :key 'inactive :width 24 :height 2
                                   ))
         (frame (etaf-posframe-panel-frame panel)))
    (unwind-protect
        (progn
          (should (frame-parameter frame 'visibility))
          (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) nil)))
            (run-hooks 'post-command-hook))
          (should-not (frame-parameter frame 'visibility))
          (cl-letf (((symbol-function 'frame-focus-state) (lambda (&rest _) t)))
            (run-hooks 'post-command-hook))
          (should (frame-parameter frame 'visibility)))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-hover-paints-a-border-without-focus ()
  "The pointer on a panel paints its border accent while the keyboard stays."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "hover"))
                                    :key 'hover-border :width 24 :height 2
                                    :focusable t))
         (frame (etaf-posframe-panel-frame panel)))
    (unwind-protect
        (progn
          (select-frame origin)
          (etaf-posframe-tests--with-pointer-on
           origin (lambda () (run-hooks 'post-command-hook)))
          (let ((resting (face-attribute 'child-frame-border :background frame)))
            ;; The hint follows the pointer, not the keyboard: the panel is not
            ;; selected, and the pointer on it still paints the accent.
            (etaf-posframe-tests--with-pointer-on
             frame (lambda () (run-hooks 'post-command-hook)))
            (should (eq (selected-frame) origin))
            (let ((accent (face-attribute 'child-frame-border :background frame)))
              (should-not (equal resting accent))
              ;; Leaving a panel runs no command in the buffer the pointer lands
              ;; in, so the package reads the pointer itself while panels are
              ;; open, and the border returns to rest without a command.
              ;; `sleep-for' drives the timers whatever input is pending.
              (etaf-posframe-tests--with-pointer-on
               origin (lambda () (sleep-for 0.6)))
              (should (equal resting
                             (face-attribute 'child-frame-border :background
                                             frame))))))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-click-selects-a-panel ()
  "A mouse button anywhere in a panel selects it, and never a passive panel."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "click"))
                                    :key 'click-panel :width 24 :height 2
                                    :focusable t))
         (frame (etaf-posframe-panel-frame panel))
         (window (frame-root-window frame))
         (passive (etaf-posframe-show (etaf-view (text "passive"))
                                      :key 'click-passive :width 24 :height 2
                                      :focusable nil))
         (passive-window (frame-root-window
                          (etaf-posframe-panel-frame passive))))
    (unwind-protect
        (progn
          (select-frame origin)
          ;; The click command has already run; the hook raises the clicked
          ;; panel and gives it the keyboard like a click on any window.
          (let ((last-command-event
                 (list 'mouse-1 (list window 1 '(1 . 1) 0))))
            (run-hooks 'post-command-hook))
          (should (eq (selected-frame) frame))
          ;; A passive panel is raised but never takes the keyboard.
          (select-frame origin)
          (let ((last-command-event
                 (list 'mouse-1 (list passive-window 1 '(1 . 1) 0))))
            (run-hooks 'post-command-hook))
          (should (eq (selected-frame) origin)))
      (ignore-errors (etaf-posframe-hide panel))
      (ignore-errors (etaf-posframe-hide passive))
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-theme-pins-a-mode ()
  "A pinned Theme keeps its mode whatever the Emacs theme is.
A pin that agrees with the frame keeps the frame's surface, so following the
theme and pinning to its own mode paint the same panel; a pin that disagrees
still stays on its polarity instead of following the frame."
  (let* ((mode (frame-parameter nil 'background-mode))
         (auto (etaf-posframe-theme nil))
         (dark (etaf-posframe-theme nil 'dark))
         (light (etaf-posframe-theme nil 'light))
         (luminance #'etaf-posframe-tests--luminance))
    (unwind-protect
        (progn
          (should (< (funcall luminance (plist-get dark :ui-bg))
                     (funcall luminance (plist-get light :ui-bg))))
          ;; Following the theme and pinning to the theme's own mode agree.
          (set-frame-parameter nil 'background-mode
                               (if (eq (plist-get auto :ui-mode) 'dark)
                                   'dark 'light))
          (should (equal (plist-get (etaf-posframe-theme nil) :ui-panel-bg)
                         (plist-get dark :ui-panel-bg)))
          ;; The opposite pin keeps its polarity when the frame's mode moves.
          (set-frame-parameter nil 'background-mode
                               (if (eq mode 'dark) 'light 'dark))
          (should (< (funcall luminance
                              (plist-get (etaf-posframe-theme nil 'dark) :ui-bg))
                     0.4))
          (should (> (funcall luminance
                              (plist-get (etaf-posframe-theme nil 'light) :ui-bg))
                     0.6)))
      (set-frame-parameter nil 'background-mode mode))))

(ert-deftest etaf-posframe-hover-is-dimmer-than-focus ()
  "Focus and hover mix the accent into the surface at their own strength."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (palette (etaf-posframe-theme origin))
         (surface (plist-get palette :ui-panel-bg))
         (accent (plist-get palette :ui-accent))
         (etaf-posframe-border-focus-strength 0.45)
         (etaf-posframe-border-hover-strength 0.20)
         (panel (etaf-posframe-show (etaf-view (text "tone"))
                                    :key 'hover-tone :width 24 :height 2
                                    :focusable t))
         (frame (etaf-posframe-panel-frame panel)))
    (unwind-protect
        (progn
          (should (eq (selected-frame) frame))
          (should (equal (etaf-posframe-tests--mix surface accent 0.45)
                         (face-attribute 'child-frame-border :background frame)))
          (select-frame origin)
          (etaf-posframe-tests--with-pointer-on
           origin (lambda () (run-hooks 'post-command-hook)))
          (let ((resting (face-attribute 'child-frame-border :background frame)))
            (should (equal (plist-get palette :ui-panel-border) resting))
            (etaf-posframe-tests--with-pointer-on
             frame (lambda () (run-hooks 'post-command-hook)))
            (let ((hover (face-attribute 'child-frame-border :background frame)))
              (should (equal (etaf-posframe-tests--mix surface accent 0.20)
                             hover))
              (should-not (equal hover resting)))))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-provides-the-panel-appearance ()
  "A View reads the panel's appearance, pinned or following the frame."
  (skip-unless (display-graphic-p))
  (let ((panel (etaf-posframe-show
                (etaf-view (expr (format "appearance:%s" (etaf-appearance))))
                :key 'appearance :width 24 :height 2
                :theme 'light)))
    (unwind-protect
        (should (string-match-p
                 "appearance:light"
                 (with-current-buffer (window-buffer
                                       (frame-root-window
                                        (etaf-posframe-panel-frame panel)))
                   (buffer-substring-no-properties (point-min) (point-max)))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-fraction-size-follows-the-frame ()
  "A (fraction F) width takes that share of the parent frame."
  (skip-unless (display-graphic-p))
  (let* ((parent (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "x"))
                                    :key 'fraction :width '(fraction 0.5)
                                    :height 2 :title "half")))
    (unwind-protect
        (let* ((frame (etaf-posframe-panel-frame panel))
               (width (frame-pixel-width frame))
               (expected (* 0.5 (frame-pixel-width parent))))
          (should (< (abs (- width expected))
                     (* 3 (frame-char-width parent)))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-focus-on-open-controls-the-first-selection ()
  "A focusable panel takes the keyboard on open only when asked."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (quiet (etaf-posframe-show (etaf-view (text "quiet"))
                                    :key 'quiet :width 20 :height 2
                                    :focusable t :focus-on-open nil))
         (frame (etaf-posframe-panel-frame quiet)))
    (unwind-protect
        (progn
          (should-not (eq (selected-frame) frame))
          (etaf-posframe-hide quiet)
          (setq quiet (etaf-posframe-show (etaf-view (text "loud"))
                                          :key 'loud :width 20 :height 2
                                          :focusable t :focus-on-open t)
                frame (etaf-posframe-panel-frame quiet))
          (should (eq (selected-frame) frame)))
      (ignore-errors (etaf-posframe-hide quiet))
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-keep-alive-resumes-the-session ()
  "A :keep-alive app is hidden and resumed; quitting stops it once."
  (skip-unless (display-graphic-p))
  (let ((saved-apps etaf-posframe-apps)
        (saved-map etaf-posframe-app-map)
        (created 0) (stopped 0) (sessions nil))
    (unwind-protect
        (progn
          (etaf-posframe-register-app 'keep-test
                                      :title "Keep" :shortcut "k"
                                      :keep-alive t
                                      :create (lambda () (cl-incf created) (list :id :session))
                                      :view (lambda (session)
                                              (push session sessions)
                                              (etaf-view (text "keep")))
                                      :on-stop (lambda (_session) (cl-incf stopped))
                                      :width 20 :height 2)
          (let* ((first (etaf-posframe-app 'keep-test))
                 (session (car sessions))
                 (second nil))
            (should (etaf-posframe-live-p first))
            (etaf-posframe-app 'keep-test)
            (should-not (etaf-posframe-live-p first))
            ;; A real toggle a moment later is not the repeat guard's target.
            (sleep-for 0.5)
            (setq second (etaf-posframe-app 'keep-test))
            (should (etaf-posframe-live-p second))
            (should (= created 1))
            (should (eq (car sessions) session))
            (etaf-posframe-app-quit 'keep-test)
            (should (= stopped 1))
            (should-not (memq second (etaf-posframe-panels)))))
      (ignore-errors (etaf-posframe-app-quit 'keep-test))
      (setq etaf-posframe-apps saved-apps
            etaf-posframe-app-map saved-map))))

(ert-deftest etaf-posframe-pointer-leaving-keeps-the-focus-border ()
  "Moving the pointer off a focused panel keeps its focused border."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "stay"))
                                    :key 'stay :width 20 :height 2
                                    :focusable t :focus-on-open t))
         (frame (etaf-posframe-panel-frame panel)))
    (unwind-protect
        (progn
          (should (eq (selected-frame) frame))
          (let ((accent (face-attribute 'child-frame-border :background frame)))
            (etaf-posframe-tests--with-pointer-on
             origin (lambda () (run-hooks 'post-command-hook)))
            (should (eq (selected-frame) frame))
            (should (equal accent
                           (face-attribute 'child-frame-border :background
                                           frame)))))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-theme-answers-for-its-own-frame ()
  "A frame's palette does not depend on which frame is selected.
`face-attribute' with an explicit nil inherit answers for the selected frame,
so a panel that held the keyboard used to derive its palette from itself."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'theme-frame :width 20 :height 2
                                    :focusable t :focus-on-open t))
         (frame (etaf-posframe-panel-frame panel))
         (parent (frame-parent frame)))
    (unwind-protect
        (progn
          ;; The panel holds the keyboard while its palette is derived.
          (should (eq (selected-frame) frame))
          (let ((palette (etaf-posframe-theme parent)))
            (should (equal (face-attribute 'default :background parent)
                           (plist-get palette :ui-bg)))
            (should-not (equal (frame-parameter frame 'background-color)
                               (plist-get palette :ui-bg)))
            ;; The same function still answers for the frame it was given.
            (should (equal (plist-get (etaf-posframe-theme frame) :ui-bg)
                           (frame-parameter frame 'background-color)))))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame-set-input-focus origin)))))

(ert-deftest etaf-posframe-theme-switch-lands-in-one-pass ()
  "A theme switch repaints a focused panel from its parent frame's palette.
The switch used to leave the panel on the old surface behind a 0.1 s timer,
and a focused panel derived a wrong palette from the frame it had selected."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (enabled (copy-sequence custom-enabled-themes))
         (panel (etaf-posframe-show (etaf-view (text "panel"))
                                    :key 'theme-switch :width 24 :height 2
                                    :title "ETAF"))
         (frame (etaf-posframe-panel-frame panel))
         (header (lambda ()
                   (with-current-buffer (window-buffer (frame-root-window frame))
                     (let ((face (get-text-property 0 'face header-line-format)))
                       (and (listp face) (plist-get face :background))))))
         (before (funcall header)))
    (unwind-protect
        (progn
          ;; A focused panel is the case that used to derive its own colours.
          (select-frame frame)
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme 'modus-vivendi t)
          ;; The coalesced pass runs as soon as Emacs waits again.
          (sleep-for 0.2)
          (let* ((parent (frame-parent frame))
                 (palette (etaf-posframe-theme parent)))
            (should (eq 'dark (plist-get palette :ui-mode)))
            (should (equal (face-attribute 'default :background parent)
                           (plist-get palette :ui-bg)))
            ;; The panel frame paints its surface, not the page behind it.
            (should (equal (plist-get palette :ui-panel-bg)
                           (frame-parameter frame 'background-color)))
            (should (equal (plist-get palette :ui-fg)
                           (frame-parameter frame 'foreground-color)))
            ;; The title bar follows the same palette in the same pass.
            (should-not (equal before (funcall header)))))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame origin))
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (theme enabled)
        (ignore-errors (load-theme theme t))))))

(defun etaf-posframe-tests--header-segment (header caption)
  "Return the position of CAPTION's segment in HEADER, or nil."
  (cl-loop for i from 0 below (1- (length header))
           for map = (get-text-property i 'keymap header)
           when (and map (string= caption (substring-no-properties
                                           header (1+ i) (+ 2 i))))
           return i))

(ert-deftest etaf-posframe-title-bar-toggles-theme-mode ()
  "A click on a title-bar segment repaints the panel on that mode.
The `:theme' option is the initial value; the toggle changes the panel for its
own lifetime without touching the caller's configuration, and the selected
segment takes no pointer-hover face, so its label stays readable."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (enabled (copy-sequence custom-enabled-themes))
         (panel (etaf-posframe-show (etaf-view (text "tone"))
                                    :key 'theme-toggle :width 40 :height 2
                                    :title "ETAF" :theme 'auto))
         (frame (etaf-posframe-panel-frame panel))
         (luminance #'etaf-posframe-tests--luminance))
    (unwind-protect
        (let* ((buffer (etaf-posframe-tests--panel-buffer frame))
               (header (with-current-buffer buffer header-line-format))
               (before (frame-parameter frame 'background-color))
               ;; Click the segment the panel is not already showing.
               (caption (if (< (funcall luminance before) 0.5) "亮" "暗"))
               (position (etaf-posframe-tests--header-segment header caption))
               (selected (etaf-posframe-tests--header-segment header "随"))
               (command (and position
                             (lookup-key (get-text-property position 'keymap header)
                                         [header-line mouse-1]))))
          (should position)
          (should command)
          ;; Every segment is present, and the selected one has no hover face.
          (should (etaf-posframe-tests--header-segment header "亮"))
          (should (etaf-posframe-tests--header-segment header "随"))
          (should (etaf-posframe-tests--header-segment header "暗"))
          (should-not (get-text-property selected 'mouse-face header))
          (should (get-text-property position 'mouse-face header))
          (call-interactively command)
          (let ((after (frame-parameter frame 'background-color)))
            (should-not (equal before after))
            (if (string= caption "亮")
                (should (> (funcall luminance after) 0.5))
              (should (< (funcall luminance after) 0.5))))
          ;; The toggle is a session setting: the Emacs themes are untouched.
          (should (equal enabled custom-enabled-themes)))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame origin))
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (theme enabled)
        (ignore-errors (load-theme theme t))))))

(defconst etaf-posframe-tests--app-palettes
  `((day . ,(etaf-ui-theme-tokens '(:bg "#FFFFFF" :fg "#1B2027"
                                    :panel "#F4F6FA" :border "#DDE2EA"
                                    :muted "#5C6470" :accent "#2F6FE4"
                                    :accent-fg "#FFFFFF")))
    (night . ,(etaf-ui-theme-tokens '(:bg "#0D1014" :fg "#DDE3EC"
                                      :panel "#12151A" :border "#262B33"
                                      :muted "#8A94A3" :accent "#6CB6FF"
                                      :accent-fg "#101418"))))
  "Palettes the test application owns, keyed by its own mode.")

(defvar etaf-posframe-tests--surface-mode nil
  "Mode cell of the test application while a case runs.")

(defvar etaf-posframe-tests--surface-theme nil
  "Palette cell of the test application while a case runs.")

(etaf-define-component etaf-posframe-tests-surface-app ()
  "Declare an application palette and switch on its own mode cell.
The palette follows the mode cell, the way an application that owns its
palette repaints."
  :setup (progn
           (etaf-watch
            (lambda () (etaf-value etaf-posframe-tests--surface-mode))
            (lambda (new _old)
              (etaf-set-value etaf-posframe-tests--surface-theme
                              (alist-get new etaf-posframe-tests--app-palettes)))
            :immediate t)
           (when-let* ((surface (etaf-surface-host)))
             (etaf-surface-declare surface
                                   :theme etaf-posframe-tests--surface-theme
                                   :mode etaf-posframe-tests--surface-mode
                                   :modes '((day . "晨") (night . "夜")))))
  :view (text (expr (format "app:%s"
                            (etaf-value etaf-posframe-tests--surface-mode)))))

(ert-deftest etaf-posframe-title-bar-and-the-application-share-one-theme-state ()
  "A panel paints what its content declares, and both switches write one cell.
The application's own toggle repaints the panel, and a click on the panel's
title bar switches the application; the palette and the mode are one state,
not one per surface."
  (skip-unless (display-graphic-p))
  (let* ((origin (etaf-posframe-tests--top-frame))
         (mode (etaf-ref 'night))
         (theme (etaf-ref (alist-get 'night etaf-posframe-tests--app-palettes)))
         (etaf-posframe-tests--surface-mode mode)
         (etaf-posframe-tests--surface-theme theme)
         (panel (etaf-posframe-show
                 (etaf-view (etaf-posframe-tests-surface-app))
                 :key 'surface-app :width 36 :height 2 :title "APP" :theme 'auto))
         (frame (etaf-posframe-panel-frame panel)))
    (unwind-protect
        (let ((buffer (etaf-posframe-tests--panel-buffer frame)))
          ;; The frame paints the application's palette, not one derived from
          ;; the Emacs theme.
          (should (equal (frame-parameter frame 'background-color)
                         (plist-get (alist-get 'night
                                               etaf-posframe-tests--app-palettes)
                                    :ui-panel-bg)))
          ;; The title bar offers the application's modes and selects its mode.
          (let* ((header (with-current-buffer buffer header-line-format))
                 (day (etaf-posframe-tests--header-segment header "晨"))
                 (night (etaf-posframe-tests--header-segment header "夜")))
            (should day)
            (should night)
            (should-not (get-text-property night 'mouse-face header))
            ;; The application's own switch repaints the panel around it.
            (etaf-set-value mode 'day)
            (should (equal (frame-parameter frame 'background-color)
                           (plist-get (alist-get 'day
                                                 etaf-posframe-tests--app-palettes)
                                      :ui-panel-bg)))
            (should (string-match-p
                     "app:day"
                     (with-current-buffer buffer
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (setq header (with-current-buffer buffer header-line-format))
            (let ((command (lookup-key (get-text-property
                                        (etaf-posframe-tests--header-segment
                                         header "夜")
                                        'keymap header)
                                       [header-line mouse-1])))
              (should command)
              ;; A click on the title bar writes the application's own cell.
              (call-interactively command)
              (should (eq 'night (etaf-value mode)))
              (should (equal (frame-parameter frame 'background-color)
                             (plist-get (alist-get 'night
                                                   etaf-posframe-tests--app-palettes)
                                        :ui-panel-bg)))
              (should (string-match-p
                       "app:night"
                       (with-current-buffer buffer
                         (buffer-substring-no-properties
                          (point-min) (point-max))))))))
      (etaf-posframe-hide panel)
      (ignore-errors (select-frame origin)))))

;;; Terminal child frames

(defun etaf-posframe-test--tty-p ()
  "Return non-nil in an interactive terminal with child frames.
The batch runner has no terminal, so these cases skip there and run under
`make tty-test', which starts Emacs on a real pty."
  (and (not noninteractive)
       (not (display-graphic-p))
       (featurep 'tty-child-frames)))

(defun etaf-posframe-test--tty-fits-p (panel)
  "Return non-nil when PANEL, border included, stays inside the terminal."
  (let* ((frame (etaf-posframe-panel-frame panel))
         (position (frame-position frame)))
    (and frame
         (>= (car position) 1)
         (>= (cdr position) 1)
         (<= (+ (car position) (frame-width frame) 1)
             (frame-pixel-width (frame-parent frame)))
         (<= (+ (cdr position) (frame-height frame) 1)
             (frame-pixel-height (frame-parent frame))))))

(ert-deftest etaf-posframe-tty-shows-a-panel-in-cells ()
  "A terminal panel keeps its column width and content rows on screen."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (column (text "Build finished")
                                  (text "3 tests failed in parser-tests"))))
         (panel (etaf-posframe-show view :width 30 :key 'tty-shows :auto-hide nil)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (let ((frame (etaf-posframe-panel-frame panel)))
            (should (= 30 (frame-width frame)))
            (should (= 2 (frame-height frame)))
            (should (etaf-posframe-test--tty-fits-p panel))
            (should (string-match-p
                     "Build finished"
                     (with-current-buffer (window-buffer (frame-root-window frame))
                       (buffer-substring-no-properties (point-min) (point-max)))))))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-tty-fill-keeps-the-row-budget ()
  "A terminal panel keeps the rows it asked for, not a pixel margin's worth."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (text "filled")))
         (panel (etaf-posframe-show view :width 24 :height 10
                                    :fill-height t :key 'tty-fill :auto-hide nil)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (should (= 10 (frame-height (etaf-posframe-panel-frame panel))))
          (should (etaf-posframe-test--tty-fits-p panel)))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-tty-title-adds-only-the-header ()
  "A titled terminal panel height is its header plus its content rows."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (column (text "one") (text "two"))))
         (panel (etaf-posframe-show view :width 24 :title "Panel"
                                    :key 'tty-title :auto-hide nil)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (should (= 3 (frame-height (etaf-posframe-panel-frame panel))))
          (should (etaf-posframe-test--tty-fits-p panel)))
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-tty-stack-leaves-one-cell ()
  "Terminal panels stacked at one anchor stay one cell apart."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (text "stacked")))
         (first (etaf-posframe-show view :at 'frame-top-right :stack t
                                    :key 'tty-stack-a :auto-hide nil :width 24))
         (second (etaf-posframe-show view :at 'frame-top-right :stack t
                                     :key 'tty-stack-b :auto-hide nil :width 24)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (let* ((a (etaf-posframe-panel-frame first))
                 (b (etaf-posframe-panel-frame second))
                 (gap (- (cdr (frame-position b))
                         (+ (cdr (frame-position a)) (frame-height a) 2))))
            (should (= 1 gap))
            (should (= (car (frame-position a)) (car (frame-position b))))
            (should (etaf-posframe-test--tty-fits-p first))
            (should (etaf-posframe-test--tty-fits-p second))))
      (etaf-posframe-hide first)
      (etaf-posframe-hide second))))

(ert-deftest etaf-posframe-tty-anchors-keep-the-border-on-screen ()
  "Every frame anchor keeps a terminal panel and its border inside the frame."
  (skip-unless (etaf-posframe-test--tty-p))
  (let ((view (etaf-view (text "edge"))))
    (dolist (at '(frame-top-left frame-top-right frame-bottom-left
                  frame-bottom-right frame-center))
      (let ((panel (etaf-posframe-show view :at at :width 24
                                      :key at :auto-hide nil)))
        (unwind-protect
            (progn
              (etaf-posframe-test--settle 0.1)
              (should (etaf-posframe-test--tty-fits-p panel)))
          (etaf-posframe-hide panel))))))

(ert-deftest etaf-posframe-tty-refit-keeps-a-panel-inside ()
  "A resized terminal frame re-places its panel and its border on screen."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (text "refit")))
         (parent (selected-frame))
         (columns (frame-width parent))
         (rows (frame-height parent))
         (panel (etaf-posframe-show view :at 'frame-bottom-right :width 24
                                    :key 'tty-refit :auto-hide nil)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (set-frame-size parent (max 40 (- columns 20)) (max 20 (- rows 10)) t)
          (etaf-posframe-test--settle 0.3)
          (should (etaf-posframe-test--tty-fits-p panel)))
      (set-frame-size parent columns rows t)
      (etaf-posframe-test--settle 0.2)
      (etaf-posframe-hide panel))))

(ert-deftest etaf-posframe-tty-hide-releases-the-frame ()
  "Hiding a terminal panel deletes its frame and its Runtime."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (text "gone")))
         (panel (etaf-posframe-show view :width 24 :key 'tty-hide :auto-hide nil))
         (frame (etaf-posframe-panel-frame panel)))
    (should (frame-live-p frame))
    (should (etaf-posframe-hide panel))
    (should-not (etaf-posframe-live-p panel))
    (should-not (frame-live-p frame))
    (should-not (etaf-posframe-panels))))

(ert-deftest etaf-posframe-tty-move-keeps-the-place ()
  "Moving a terminal panel keeps the new place through a refresh."
  (skip-unless (etaf-posframe-test--tty-p))
  (let* ((view (etaf-view (text "move")))
         (panel (etaf-posframe-show view :at 'frame-top-left :width 20 :height 3
                                    :key 'tty-move :auto-hide nil)))
    (unwind-protect
        (progn
          (etaf-posframe-test--settle 0.2)
          (let* ((frame (etaf-posframe-panel-frame panel))
                 (start (frame-position frame)))
            (etaf-posframe-move 'right 2 panel)
            (etaf-posframe-move 'down 1 panel)
            (should (= (+ (car start) 2) (car (frame-position frame))))
            (should (= (+ (cdr start) 1) (cdr (frame-position frame))))
            (etaf-posframe-refresh panel)
            (etaf-posframe-test--settle 0.2)
            (should (= (+ (car start) 2) (car (frame-position frame))))
            (should (= (+ (cdr start) 1) (cdr (frame-position frame))))))
      (etaf-posframe-hide panel))))

(provide 'etaf-posframe-tests)
;;; etaf-posframe-tests.el ends here
