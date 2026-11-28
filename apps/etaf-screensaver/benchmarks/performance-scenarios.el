;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Autonomous screensaver frame cadence

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Run through the workspace performance.py driver.  A sample waits for the
;; next autonomous frame, including timer wait, computation and publication.
;; Version 2 replaces the retired manual-step workspace workload and is not
;; comparable to it.  Cleanup restores the driver's original window state.

;;; Code:
(require 'etaf-screensaver)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-screensaver-benchmark--fixture (scene &optional presentation)
  "Return a seeded cadence fixture for SCENE with PRESENTATION."
  (let* ((etaf-screensaver-seed 4242)
         (etaf-screensaver-max-frame-rate 30)
         (buffer (etaf-screensaver-start
                  (if (eq presentation 'mosaic)
                      '(:presentation mosaic :scenes
                        ((:scene tte-beams :duration 3600 :frame-rate 30)
                         (:scene tte-synthgrid :duration 3600)
                         (:scene tte-ink-river :duration 3600)
                         (:scene benchmark-large :duration 3600)))
                    (list :scene scene :duration 3600 :frame-rate 30
                          :presentation (or presentation 'full)))))
         (ticks 0))
    (list :buffer buffer
          :prepare (lambda () (setq ticks (plist-get (etaf-screensaver-status) :ticks)))
          :invoke #'ignore
          :settled (lambda ()
                     (let ((now (plist-get (etaf-screensaver-status) :ticks)))
                       (and now (> now ticks))))
          :verify (lambda ()
                    (let ((status (etaf-screensaver-status)))
                      (if (and (plist-get status :active)
                               (eq (plist-get status :scene) scene)
                               (> (plist-get status :ticks) ticks))
                          t "The autonomous scene did not publish another frame")))
          :cleanup #'etaf-screensaver-stop)))

(etaf-screensaver-register-reel
 (list :id 'benchmark-frames :provider 'frames :frame-rate 30
       :recording (expand-file-name "../tests/fixtures/frames/sample.frames.json"
                                    (file-name-directory
                                     (locate-library "etaf-screensaver-loader")))
       :title "Baked fixture"))

(dolist (scene '(plasma matrix snow equalizer tte-blackhole benchmark-frames))
  (taf-benchmark-register
   (format "etaf-screensaver.frame.%s" scene)
   :version 2 :modes '(batch gui) :isolation 'series :impact 'local
   :budget-ms 100
   :description (format "Wait for the next autonomous %s frame at a 30 fps cap" scene)
   :setup (lambda (_mode) (etaf-screensaver-benchmark--fixture scene))))

(etaf-screensaver-register-reel
 (list :id 'benchmark-large :provider 'frames :frame-rate 30
       :recording (expand-file-name "../tests/fixtures/frames/large.frames.json"
                                    (file-name-directory
                                     (locate-library "etaf-screensaver-loader")))
       :title "960x540 JPEG fixture"))

(dolist (style '(full card band mosaic))
  (let ((style style))
    (taf-benchmark-register
     (format "etaf-screensaver.presentation.%s" style)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'local
     :budget-ms 100
     :description (format "Autonomous %s composition with native 960x540 JPEG frames" style)
     :setup (lambda (_mode)
              (etaf-screensaver-benchmark--fixture
               (if (eq style 'mosaic) 'tte-beams 'benchmark-large) style)))))

(defun etaf-screensaver-benchmark--gallery (style mode &optional playback)
  "Play real works in STYLE and MODE with optional boundary/transition PLAYBACK.
GUI playback always keeps a work's natural 24-second dwell: rapid alternation
between light and dark pages must never be used on a visible desktop.  Batch
boundary screens use 0.8 seconds.  GUI runs need --timeout 40 for preparation.
Missing or different-sized gallery data fails setup instead of substituting
a tiny fixture.  Generate the gallery outside Git with bake-gallery.mjs."
  (let* ((directory (expand-file-name
                     (or (getenv "ETAF_SCREENSAVER_GALLERY")
                         "etaf-screensaver/scenes/gallery")
                     user-emacs-directory))
         (boundary (eq playback 'boundary))
         (dwell (if (eq mode 'gui) 24.0 0.8))
         (primed nil)
         (works '(paper-flock orbital-mobile blueprint kinetic-dots))
         (signatures
          (mapcar
           (lambda (work)
             (let ((file (expand-file-name (format "%s/%s.frames.json" work work) directory)))
               (with-temp-buffer
                 (insert-file-contents file)
                 (let ((data (json-parse-buffer :object-type 'plist :array-type 'array)))
                   (unless (and (= (plist-get data :width) 960)
                                (= (plist-get data :height) 540)
                                (= (plist-get data :frame_rate) 15)
                                (= (length (plist-get data :frames)) 360))
                     (error "Expected the full-size 24-second gallery: %s" file)))
                 (secure-hash 'sha256 (current-buffer)))))
           works))
         (etaf-screensaver-seed 4242)
         (etaf-screensaver-max-frame-rate 30)
         (etaf-screensaver-presentation style)
         (_loaded (etaf-screensaver-load-scenes (list directory)))
         (buffer (etaf-screensaver-start
                  (list :scenes
                        (mapcar (lambda (work)
                                  (list :scene (intern (format "frames-%s" work))
                                        :duration (if playback dwell 3600)))
                                works))))
         (index 0) (ticks 0))
    (list :buffer buffer
          :environment (lambda () (list :gallery (vconcat signatures)
                                        :playback (when playback (symbol-name playback))))
          :prepare (lambda ()
                     ;; Wait outside timing for the last native frame interval.
                     ;; The timed operation still includes the boundary's work,
                     ;; its publication and redisplay; none is preloaded here.
                     (when (or boundary (and playback (not primed)))
                       (let* ((status (etaf-screensaver-status))
                              (page (plist-get status :index))
                              (elapsed (or (plist-get status :elapsed) 0))
                              (observed-at (float-time))
                              (deadline (+ observed-at dwell 5))
                              (target (- dwell (if boundary (/ 1.0 15) 0.6))))
                         ;; Public elapsed time is sampled at frame ticks.  A
                         ;; jittered last tick can be below TARGET even though
                         ;; the next tick changes the page.  Interpolate only
                         ;; the wait between observed ticks, not the measured
                         ;; boundary work, instead of requiring that narrow
                         ;; discrete value to occur at all.
                         (while (< (+ elapsed (- (float-time) observed-at)) target)
                           (sleep-for 0.005)
                           (setq status (etaf-screensaver-status))
                           (unless (and (< (float-time) deadline)
                                        (plist-get status :active)
                                        (eql (plist-get status :index) page))
                             (error "Gallery preparation lost page %S: active=%S index=%S elapsed=%S target=%S"
                                    page (plist-get status :active)
                                    (plist-get status :index)
                                    (plist-get status :elapsed) target))
                           (unless (= (plist-get status :elapsed) elapsed)
                             (setq elapsed (plist-get status :elapsed)
                                   observed-at (float-time)))))
                       (setq primed t))
                     (let ((status (etaf-screensaver-status)))
                       (setq index (plist-get status :index)
                             ticks (plist-get status :ticks))))
          :invoke #'ignore
          :settled (lambda ()
                     (let ((status (etaf-screensaver-status)))
                       (and (plist-get status :active)
                            (or (> (plist-get status :index) index)
                                (and (not boundary) (> (plist-get status :ticks) ticks))))))
          :verify (lambda ()
                    (let ((status (etaf-screensaver-status)))
                      (if (and (plist-get status :active)
                               (eq (plist-get status :presentation) style)
                               (if boundary (> (plist-get status :index) index)
                                 (or (> (plist-get status :index) index)
                                     (> (plist-get status :ticks) ticks))))
                          t "The real gallery did not publish the expected frame/page")))
          :cleanup #'etaf-screensaver-stop)))

(dolist (style '(full card band mosaic))
  (let ((style style))
    (taf-benchmark-register
     (format "etaf-screensaver.gallery.%s" style)
     :version 2 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 100
     :description "Native 15 fps gallery: four distinct 960x540, 360-frame bundles"
     :setup (lambda (mode) (etaf-screensaver-benchmark--gallery style mode)))))

(taf-benchmark-register
 "etaf-screensaver.gallery.boundary"
 :version 3 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 100
 :description "Natural 24-second GUI boundaries across full-size gallery bundles"
 :setup (lambda (mode) (etaf-screensaver-benchmark--gallery 'full mode 'boundary)))

(taf-benchmark-register
 "etaf-screensaver.gallery.transition"
 :version 3 :modes '(batch gui) :isolation 'series :impact 'local :budget-ms 100
 :description "Native frames spanning a natural gallery page change (no rapid GUI cuts)"
 :setup (lambda (mode) (etaf-screensaver-benchmark--gallery 'full mode 'transition)))

(provide 'etaf-screensaver-performance-scenarios)
;;; performance-scenarios.el ends here
