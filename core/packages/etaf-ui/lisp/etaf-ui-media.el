;;; etaf-ui-media.el --- In-buffer image and video viewer -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A modal viewer drawn on the application's root layer.  The media is sized
;; to the live viewport at its own aspect ratio; video gets a transport bar
;; driven by the public `etaf-video' control functions.

;;; Code:
(require 'etaf-ui-surface)
(require 'etaf-ui-icon)
(require 'etaf-ui-selection)

;; Source dimensions are probed only when native images are available.
(declare-function image-size "image.c" (spec &optional pixels frame))

(defun etaf-ui--media-video-driver (&optional ensure)
  "Return the registered `etaf-video-driver' plist, loading `etaf-media' if ENSURE."
  (when (and ensure (null etaf-video-driver) (locate-library "etaf-media"))
    (ignore-errors (load "etaf-media" t t)))
  etaf-video-driver)

(defun etaf-ui--media-ffplay-program ()
  "Return the configured ffplay executable name."
  (let ((fn (plist-get (etaf-ui--media-video-driver) :ffplay-program)))
    (or (and (functionp fn) (ignore-errors (funcall fn)))
        "ffplay")))

(defun etaf-ui--media-audio-default ()
  "Return whether media playback defaults to audio enabled."
  (let ((fn (plist-get (etaf-ui--media-video-driver) :audio-default)))
    (if (functionp fn) (and (ignore-errors (funcall fn)) t) t)))

(defun etaf-ui--media-volume-default ()
  "Return the default media playback volume (0..100)."
  (let ((fn (plist-get (etaf-ui--media-video-driver) :volume-default)))
    (or (and (functionp fn) (ignore-errors (funcall fn)))
        100)))

(defconst etaf-ui--media-colors
  '(:scrim "#0E1116" :fg "#E8ECF1" :muted "#8E99A8" :control "#C9D1DB"
    :track "#2A313B")
  "Fixed dark palette of the viewer, independent of the application theme.")

(defconst etaf-ui--media-speeds '(1 1.25 1.5 2 0.5)
  "Playback rates cycled by the speed control.")

(defconst etaf-ui--media-gutter 6
  "Columns reserved on each side of the stage for navigation arrows.")

(defun etaf-ui--media-color (key)
  "Return the viewer palette color KEY."
  (plist-get etaf-ui--media-colors key))

(defun etaf-ui--media-clock (seconds)
  "Return SECONDS as M:SS, or H:MM:SS from one hour."
  (let ((total (max 0 (floor (or seconds 0)))))
    (if (>= total 3600)
        (format "%d:%02d:%02d" (/ total 3600) (/ (% total 3600) 60) (% total 60))
      (format "%d:%02d" (/ total 60) (% total 60)))))

(defun etaf-ui--media-audio-start (src position speed volume on-exit)
  "Start an ffplay process for audio SRC at POSITION, SPEED and VOLUME.
ON-EXIT receives the process when it stops.  Return the process, or nil
when ffplay is unavailable or the process cannot start."
  (when-let* ((program (executable-find (etaf-ui--media-ffplay-program))))
    (let ((buffer (generate-new-buffer " *etaf-ui audio*")))
      (condition-case nil
          (make-process
           :name "etaf-ui-audio"
           :command (append (list program "-nodisp" "-autoexit" "-hide_banner"
                                  "-loglevel" "error"
                                  "-ss" (format "%.3f" (max 0 position))
                                  "-volume" (number-to-string (round volume)))
                            (when (and (numberp speed) (/= speed 1))
                              (list "-af" (format "atempo=%s" speed)))
                            (list src))
           :buffer buffer
           :coding '(no-conversion . no-conversion)
           :connection-type 'pipe
           :noquery t
           :sentinel (lambda (process _event)
                       (when (memq (process-status process) '(exit signal))
                         (when (buffer-live-p (process-buffer process))
                           (kill-buffer (process-buffer process)))
                         (funcall on-exit process))))
        (error (when (buffer-live-p buffer) (kill-buffer buffer)) nil)))))

(defun etaf-ui--media-natural-size (kind src size)
  "Return the pixel (WIDTH . HEIGHT) of SRC of KIND, preferring SIZE."
  (or (and (consp size) (numberp (car size)) (numberp (cdr size))
           (> (car size) 0) (> (cdr size) 0)
           size)
      (pcase kind
        ('image
         (when (display-images-p)
           (ignore-errors
             (image-size (if (stringp src) (create-image src) src) t))))
        ('video
         (ignore-errors
           (when-let* ((drv (etaf-ui--media-video-driver t))
                       (fn (plist-get drv :source-info))
                       (info (funcall fn src)))
             (when (and (numberp (plist-get info :width))
                        (numberp (plist-get info :height)))
               (cons (plist-get info :width) (plist-get info :height)))))))
      '(16 . 9)))

(defun etaf-ui--media-grid (natural width-px rows upscale)
  "Fit NATURAL pixel size into WIDTH-PX by ROWS lines as (COLUMNS . ROWS).
Keep the aspect ratio; enlarge beyond the natural size only when UPSCALE."
  (let* ((cell (etaf-ui--canvas-cell))
         (cw (max 1 (car cell)))
         (lh (max 1 (cdr cell)))
         (width (float (max 1 (car natural))))
         (height (float (max 1 (cdr natural))))
         (scale (min (/ width-px width) (/ (* rows lh) height)))
         (scale (if upscale scale (min scale 1.0))))
    (cons (max 2 (min (max 2 (floor width-px cw)) (round (/ (* width scale) cw))))
          (max 1 (min rows (round (/ (* height scale) lh)))))))

(etaf-define-component etaf-ui--media-control
    (&key icon label help on-press (width 4) ref)
  "Render one fixed-width transport control: an icon or a short LABEL."
  :render
  (etaf-node
   'box
   (list :width (list 'ch width) :height '(lh 1) :text-align 'center
         :flex-shrink 0
         :color (etaf-ui--media-color :control) :role 'button
         :aria-label help :help-echo help :tab-index -1 :ref ref
         :hover-style (list :color (etaf-ui--media-color :fg))
         :on-press on-press)
   (list (if icon
             (etaf-node 'etaf-ui-icon
                        (list :name icon :set 'svg :size 0.9 :min-width width
                              :color (etaf-ui--media-color :control))
                        nil)
           (etaf-node 'text nil (list label))))))

(etaf-define-component etaf-ui--media-viewer-open
    (&key kind src source-size title subtitle caption duration on-close
          on-previous on-next on-ended autoplay audio volume)
  "Render the open viewer and own its keys and video polling."
  :bindings
  ((panel (etaf-local-ref 'panel))
   (header (etaf-local-ref 'header))
   (stage (etaf-local-ref 'stage))
   (footer (etaf-local-ref 'footer))
   (buffer (if-let* ((runtime (etaf-current-runtime)))
               (etaf-runtime-buffer runtime)
             (current-buffer)))
   (handle (make-symbol "etaf-media-viewer"))
   (kind-input (etaf-prop 'kind))
   (src-input (etaf-prop 'src))
   (duration-input (etaf-prop 'duration))
   (close-input (etaf-prop 'on-close))
   (previous-input (etaf-prop 'on-previous))
   (next-input (etaf-prop 'on-next))
   (ended-input (etaf-prop 'on-ended))
   (playing (etaf-ref nil :name "media-playing"))
   (position (etaf-ref 0 :name "media-position"))
   (total-time (etaf-ref 0 :name "media-duration"))
   (speed (etaf-ref 1 :name "media-speed"))
   (audio-ref (etaf-ref (if (eq audio :default) (etaf-ui--media-audio-default) (and audio t))
                        :name "media-audio"))
   (volume-ref (etaf-ref (max 0 (min 100 (round (or volume (etaf-ui--media-volume-default)))))
                         :name "media-volume"))
   (ended-seen nil)
   (ended-src nil)
   (duration-value
    (lambda ()
      (if (eq (etaf-value kind-input) 'audio)
          (or (etaf-value duration-input) 0)
        (etaf-value total-time))))
   (clock (etaf-computed
           (lambda ()
             (format "%s / %s"
                     (etaf-ui--media-clock (etaf-value position))
                     (etaf-ui--media-clock (funcall duration-value))))))
   (progress (etaf-computed
              (lambda ()
                (let ((total (funcall duration-value)))
                  (if (> total 0)
                      (min 100 (* 100.0 (/ (etaf-value position) total)))
                    0)))))
   (natural-cache (make-hash-table :test #'equal))
   (return-focus
    (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
      (delq nil (list (etaf-focused-host-ref runtime)))))
   (timer nil)
   (cursor-restore nil)
   (cleanup nil)
   (registration nil)
   (audio-process nil)
   (audio-base 0)
   (audio-stamp 0)
   (video-p (lambda () (eq (etaf-value kind-input) 'video)))
   (audio-p (lambda () (eq (etaf-value kind-input) 'audio)))
   (control (lambda (function &rest args)
              (when (funcall video-p)
                (condition-case nil (apply function handle args)
                  (user-error nil)))))
   (audio-position
    (lambda ()
      (if (and audio-process (etaf-value playing))
          (let ((total (funcall duration-value)))
            (min (if (> total 0) total most-positive-fixnum)
                 (+ audio-base (- (float-time) audio-stamp))))
        audio-base)))
   (audio-stop
    (lambda ()
      (when (and audio-process (process-live-p audio-process))
        (delete-process audio-process))
      (setq audio-process nil)))
   (audio-start
    (lambda (at)
      (funcall audio-stop)
      (let ((process (etaf-ui--media-audio-start
                      (etaf-value src-input) at (etaf-value speed)
                      (if (etaf-value audio-ref) (etaf-value volume-ref) 0)
                      (lambda (ended)
                        (when (eq ended audio-process)
                          (setq audio-process nil)
                          (etaf-set-value playing nil)
                          (etaf-set-value position (funcall duration-value))
                          (let ((cb (etaf-value ended-input)))
                            (when (functionp cb) (funcall cb))))))))
        (when (and process (process-live-p process))
          (setq audio-process process
                audio-base at
                audio-stamp (float-time))
          (etaf-set-value playing t)
          (etaf-set-value position at)))))
   (poll (lambda ()
           (cond
            ((funcall audio-p)
             (when (and audio-process (etaf-value playing))
               (etaf-set-value position (funcall audio-position))))
            ((funcall video-p)
             (let ((cur-src (etaf-value src-input)))
               (unless (equal cur-src ended-src)
                 (setq ended-src cur-src ended-seen nil)))
             (when-let* ((state-fn (plist-get (etaf-ui--media-video-driver) :state))
                         (state (ignore-errors (funcall state-fn handle))))
               (etaf-set-value playing (and (plist-get state :playing) t))
               (etaf-set-value position (or (plist-get state :position) 0))
               (etaf-set-value total-time (or (plist-get state :duration) 0))
               (if (plist-get state :ended)
                   (unless ended-seen
                     (setq ended-seen t)
                     (let ((cb (etaf-value ended-input)))
                       (when (functionp cb) (funcall cb))))
                 (setq ended-seen nil)))))))
   (toggle (lambda ()
             (cond
              ((funcall audio-p)
               (cond ((and audio-process (etaf-value playing))
                      (ignore-errors (stop-process audio-process))
                      (setq audio-base (funcall audio-position))
                      (etaf-set-value position audio-base)
                      (etaf-set-value playing nil))
                     (audio-process
                      (setq audio-stamp (float-time))
                      (ignore-errors (continue-process audio-process))
                      (etaf-set-value playing t))
                     (t (funcall audio-start (etaf-value position)))))
              (t (when-let* ((fn (plist-get (etaf-ui--media-video-driver t) :toggle)))
                   (funcall control fn))))
             (funcall poll)))
   (seek-to-seconds (lambda (seconds)
                      (let ((target (max 0 (if (> (funcall duration-value) 0)
                                               (min seconds (funcall duration-value))
                                             seconds))))
                        (if (funcall audio-p)
                            (let ((was-playing (etaf-value playing)))
                              (funcall audio-stop)
                              (setq audio-base target)
                              (etaf-set-value position target)
                              (if was-playing (funcall audio-start target)
                                (etaf-set-value playing nil)))
                          (when-let* ((fn (plist-get (etaf-ui--media-video-driver t) :seek)))
                            (funcall control fn target))
                          (etaf-set-value position target)))))
   (seek-by (lambda (delta)
              (funcall seek-to-seconds (+ (etaf-value position) delta))))
   (seek-to (lambda (percent)
              (when (> (funcall duration-value) 0)
                (funcall seek-to-seconds
                         (* (funcall duration-value) (/ percent 100.0))))))
   (cycle-speed (lambda ()
                  (etaf-set-value
                   speed (or (cadr (member (etaf-value speed) etaf-ui--media-speeds))
                             (car etaf-ui--media-speeds)))
                  (when (and (funcall audio-p) audio-process (etaf-value playing))
                    (funcall audio-start (funcall audio-position)))))
   (toggle-audio (lambda ()
                   (etaf-update-value audio-ref #'not)
                   (when (and (funcall audio-p) audio-process (etaf-value playing))
                     (funcall audio-start (funcall audio-position)))))
   (change-volume (lambda (delta)
                    (let ((next (max 0 (min 100 (+ (etaf-value volume-ref) delta)))))
                      (etaf-set-value volume-ref next)
                      (when (and (> next 0) (not (etaf-value audio-ref)))
                        (etaf-set-value audio-ref t))
                      (when (and (funcall audio-p) audio-process (etaf-value playing))
                        (funcall audio-start (funcall audio-position))))))
   (navigate (lambda (direction)
               (let ((callback (etaf-value (if (eq direction 'next)
                                               next-input
                                             previous-input))))
                 (when (functionp callback) (funcall callback)))))
   (close (lambda ()
            (funcall audio-stop)
            (let ((callback (etaf-value close-input)))
              (when (functionp callback) (funcall callback)))))
   (outside (lambda ()
              (cond
               ;; RET or SPC with point on the surface is the play key.
               ((not (etaf-event-pointer-p)) (funcall toggle))
               ((not (or (etaf-event-target-within-p header)
                         (etaf-event-target-within-p stage)
                         (etaf-event-target-within-p footer)))
                (funcall close)))))
   (swipe (lambda (direction)
            (funcall navigate (if (eq direction 'left) 'next 'previous))))
   (keys
    (list (list "q" close "Close")
          (list "SPC" toggle "Play or pause")
          (list "j" (lambda () (when (or (funcall video-p) (funcall audio-p))
                                 (funcall seek-by -10))) "Back 10 seconds")
          (list "l" (lambda () (when (or (funcall video-p) (funcall audio-p))
                                 (funcall seek-by 10))) "Forward 10 seconds")
          (list "[" (lambda () (when (or (funcall video-p) (funcall audio-p))
                                 (funcall change-volume -10))) "Volume down")
          (list "]" (lambda () (when (or (funcall video-p) (funcall audio-p))
                                 (funcall change-volume 10))) "Volume up")
          (list "p" (lambda () (funcall navigate 'previous)) "Previous")
          (list "n" (lambda () (funcall navigate 'next)) "Next")
          (list "m" toggle-audio "Mute or unmute")
          (list "." cycle-speed "Cycle speed")))
   (direction
    (lambda (direction)
      (pcase direction
        ('left (if (funcall video-p) (funcall seek-by -10) (funcall navigate 'previous))
               'handled)
        ('right (if (funcall video-p) (funcall seek-by 10) (funcall navigate 'next))
                'handled)
        (_ 'release)))))
  :setup
  (progn
    (etaf-on-mounted
     (lambda ()
       (setq cleanup (etaf-ui--surface-return buffer return-focus))
       ;; The viewer owns the whole window; a text cursor has no target.
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq cursor-restore (list (local-variable-p 'cursor-type) cursor-type))
           (setq-local cursor-type nil)))
       (when-let* ((runtime (or (etaf-current-runtime)
                                (etaf-runtime-for-buffer buffer))))
         (setq registration (cons runtime panel))
         (push registration etaf-ui--open-surfaces)
         ;; The panel itself takes focus, so Space and arrows reach the
         ;; viewer instead of activating a focused control.
         (ignore-errors (etaf-focus runtime panel)))
       (setq timer (run-at-time 0.25 0.25
                                (lambda ()
                                  (if (buffer-live-p buffer)
                                      (funcall poll)
                                    (cancel-timer timer)))))))
    (etaf-on-unmounted
     (lambda ()
       (funcall audio-stop)
       (when timer (cancel-timer timer) (setq timer nil))
       (when cleanup (funcall cleanup))
       (when (and cursor-restore (buffer-live-p buffer))
         (with-current-buffer buffer
           (if (car cursor-restore)
               (setq-local cursor-type (cadr cursor-restore))
             (kill-local-variable 'cursor-type)))
         (setq cursor-restore nil))
       (when registration
         (setq etaf-ui--open-surfaces (delq registration etaf-ui--open-surfaces)
               registration nil))
       (when-let* ((runtime (etaf-runtime-for-buffer buffer))
                   ((etaf-runtime-mounted-p runtime)))
         (dolist (target return-focus)
           (when (etaf-host-ref-position runtime target)
             (ignore-errors (etaf-focus runtime target))))))))
  :render
  (let* ((viewport (or (etaf-viewport) (etaf-runtime-viewport)))
         (lines (max 8 (or (cdr viewport) 24)))
         (cw (max 1 (car (etaf-ui--canvas-cell))))
         (video (eq kind 'video))
         (playable (memq kind '(video audio)))
         (stage-rows (max 3 (- lines 6)))
         (stage-px (max (* 4 cw)
                        (- (car viewport) (* 2 etaf-ui--media-gutter cw))))
         (natural (or (gethash (cons kind src) natural-cache)
                      (puthash (cons kind src)
                               (or (etaf-ui--media-natural-size kind src source-size)
                                   (and (eq kind 'audio) (cons 640 360)))
                               natural-cache)))
         (grid (etaf-ui--media-grid natural stage-px stage-rows playable))
         (fg (etaf-ui--media-color :fg))
         (muted (etaf-ui--media-color :muted))
         (accent (plist-get (etaf-ui--style-tokens :ui-accent) :ui-accent)))
    (cl-flet ((arrow (icon callback help)
                (etaf-node 'flex
                           (list :width (list 'ch etaf-ui--media-gutter)
                                 :height (list 'lh stage-rows)
                                 :justify-content 'center :align-items 'center)
                           (when callback
                             (list (etaf-node 'etaf-ui--media-control
                                              (list :icon icon :help help
                                                    :on-press callback)
                                              nil)))))
              (air () (etaf-node 'box (list :height '(lh 1)) nil)))
      (etaf-node
       'column
       (list :ref panel :role 'dialog :aria-label (or title "Media")
             :tab-index -1 :keymap nil :on-dismiss on-close
             :focus-scope 'modal :keys keys :on-direction direction
             :position 'absolute :layer 'root :z-index 1001
             :left '(px 0) :top '(lh 0) :width '(% 100) :height (list 'lh lines)
             :background-color (etaf-ui--media-color :scrim) :color fg
             :pointer 'arrow :on-press outside :on-swipe swipe)
       (list
        (air)
        ;; Header: title and subtitle on the left, author actions and close.
        (etaf-node
         'flex
         (list :ref header :width 'stretch :height '(lh 1)
               :justify-content 'space-between :align-items 'center
               :padding '((lh 0) (ch 2)))
         (list
          (etaf-node 'box (list :flex-grow 1 :min-width '(ch 0) :height '(lh 1)
                                :overflow 'hidden :wrap-mode 'none)
                     (list (etaf-node 'text (list :font-weight 'bold)
                                      (list (or title "")))
                           (etaf-node 'text (list :color muted)
                                      (list (if subtitle (concat "  " subtitle) "")))))
          (etaf-node 'flex (list :height '(lh 1) :align-items 'center
                                 :column-gap '(ch 1))
                     (append (etaf-current-slot 'default)
                             (list (etaf-node 'etaf-ui--media-control
                                              (list :icon 'close :help "Close (Esc)"
                                                    :on-press close)
                                              nil))))))
        (air)
        ;; Stage: the media centered between optional navigation arrows.
        (etaf-node
         'flex
         (list :width 'stretch :height (list 'lh stage-rows) :align-items 'center)
         (list
          (arrow 'chevron-left on-previous "Previous (p)")
          (etaf-node
           'flex
           (list :flex-grow 1 :min-width '(ch 0) :height (list 'lh stage-rows)
                 :justify-content 'center :align-items 'center)
           (list
            (etaf-node
             'box
             (list :ref stage
                   :width (if (eq kind 'audio) 'stretch (list 'ch (car grid)))
                   :height (if (eq kind 'audio) (list 'lh stage-rows) (list 'lh (cdr grid)))
                   :overflow 'hidden
                   :on-press (when playable toggle)
                   :help-echo (when playable "Play / pause (Space)"))
             (list
              (cond
               (video
                (let ((comp (plist-get (etaf-ui--media-video-driver t) :component)))
                  (if comp
                      (etaf-node comp
                                 (list :src src :columns (car grid) :rows (cdr grid)
                                       :handle handle :autoplay autoplay
                                       :audio audio-ref :volume volume-ref :speed speed)
                                 nil)
                    (etaf-node 'flex
                               (list :justify-content 'center :align-items 'center
                                     :width 'stretch :height (list 'lh stage-rows)
                                     :background-color (etaf-ui--media-color :track))
                               (list (etaf-node 'text (list :color muted)
                                                (list "Video playback requires `etaf-media'.")))))))
               ((eq kind 'audio)
                (etaf-node 'flex (list :flex-direction 'column :justify-content 'center
                                       :align-items 'center :width 'stretch
                                       :height (list 'lh stage-rows) :row-gap '(lh 1)
                                       :background-color (etaf-ui--media-color :track))
                           (list (etaf-ui-icon 'volume :size 2.2 :min-width 4
                                               :color (etaf-ui--media-color :control))
                                 (etaf-node 'text (list :color muted)
                                            (list (etaf-value clock)))
                                 (when caption
                                   (etaf-node 'box (list :max-width '(ch 48)
                                                         :overflow 'hidden
                                                         :wrap-mode 'none)
                                              (list (etaf-node 'text (list :color fg)
                                                               (list caption))))))))
               (t
                (etaf-node 'image (list :src src :columns (car grid)
                                        :rows (cdr grid))
                           nil)))))))
          (arrow 'chevron-right on-next "Next (n)")))
        (air)
        ;; Footer: the transport bar for playable media, the caption for images.
        (if playable
            (etaf-node
             'flex
             (list :ref footer :width 'stretch :height '(lh 1) :align-items 'center
                   :padding (list '(lh 0) (list 'ch etaf-ui--media-gutter))
                   :column-gap '(ch 1))
             (list
              (etaf-node 'etaf-ui-toggle-icon
                         (list :value playing :off 'play :on 'pause :set 'svg
                               :size 0.9 :min-width 4
                               :color (etaf-ui--media-color :control)
                               :help-echo "Play / pause (Space)"
                               :on-press toggle)
                         nil)
              (etaf-node 'etaf-ui--media-control
                         (list :label "−10" :help "Back 10 seconds (j)"
                               :on-press (lambda () (funcall seek-by -10)))
                         nil)
              (etaf-node 'etaf-ui--media-control
                         (list :label "+10" :help "Forward 10 seconds (l)"
                               :on-press (lambda () (funcall seek-by 10)))
                         nil)
              (etaf-node 'box (list :width '(ch 17) :height '(lh 1) :text-align 'center
                                    :flex-shrink 0 :color muted)
                         (list (etaf-view (text (expr (etaf-value clock))))))
              (etaf-node 'flex (list :flex-grow 1 :flex-basis '(ch 0)
                                     :min-width '(ch 4) :height '(lh 1))
                         (list (etaf-node 'etaf-range
                                          (list :min 0 :max 100 :bar-height 35
                                                :value progress
                                                :color accent
                                                :track-color (etaf-ui--media-color :track)
                                                :label "Seek"
                                                :on-commit seek-to)
                                          nil)))
              (etaf-node 'etaf-ui--media-control
                         (list :label (format "%gx" (etaf-value speed)) :width 6
                               :help "Playback speed (.)"
                               :on-press cycle-speed)
                         nil)
              (etaf-node 'etaf-ui-toggle-icon
                         (list :value audio-ref :off 'volume-mute :on 'volume :set 'svg
                               :size 0.9 :min-width 4
                               :color (etaf-ui--media-color :control)
                               :help-echo "Sound (m), Volume ([ / ])"
                               :on-press toggle-audio)
                         nil)))
          (etaf-node 'box (list :ref footer :width 'stretch :height '(lh 1)
                                :overflow 'hidden :wrap-mode 'none
                                :text-align 'center :color muted)
                     (list (or caption ""))))
        (air))))))

(etaf-define-component etaf-media-viewer
    (&key open (kind 'image) src source-size title subtitle caption duration on-close
          on-previous on-next on-ended (autoplay t) (audio :default) volume)
  "Show SRC of KIND in a controlled modal viewer over the application."
  :validate
  (progn
    (etaf-check-prop :kind kind (memq kind '(image video audio))
                     "image, video or audio")
    (etaf-check-prop :duration duration
                     (or (null duration)
                         (and (numberp duration) (>= duration 0)))
                     "nil or non-negative seconds")
    (etaf-check-prop :on-close on-close (functionp on-close) "a function")
    (etaf-check-prop :on-previous on-previous
                     (or (null on-previous) (functionp on-previous))
                     "a function or nil")
    (etaf-check-prop :on-next on-next (or (null on-next) (functionp on-next))
                     "a function or nil")
    (etaf-check-prop :on-ended on-ended (or (null on-ended) (functionp on-ended))
                     "a function or nil")
    (etaf-check-prop :volume volume
                     (or (null volume)
                         (and (numberp volume) (<= 0 volume 100)))
                     "nil or a number between 0 and 100")
    (etaf-check-prop :source-size source-size
                     (or (null source-size)
                         (and (consp source-size)
                              (natnump (car source-size)) (natnump (cdr source-size))
                              (> (car source-size) 0) (> (cdr source-size) 0)))
                     "nil or (WIDTH . HEIGHT) in pixels")
    (etaf-check-prop :title title (or (null title) (stringp title)) "a string or nil")
    (etaf-check-prop :subtitle subtitle (or (null subtitle) (stringp subtitle))
                     "a string or nil")
    (etaf-check-prop :caption caption (or (null caption) (stringp caption))
                     "a string or nil"))
  :render
  (when (etaf-ui--reactive-value open)
    (etaf-node 'etaf-ui--media-viewer-open
               (list :kind kind :src src :source-size source-size :title title
                     :subtitle subtitle :caption caption :duration duration
                     :on-close on-close
                     :on-previous on-previous :on-next on-next :on-ended on-ended
                     :autoplay autoplay :audio audio :volume volume)
               (etaf-current-slot 'default))))

(provide 'etaf-ui-media)
;;; etaf-ui-media.el ends here
