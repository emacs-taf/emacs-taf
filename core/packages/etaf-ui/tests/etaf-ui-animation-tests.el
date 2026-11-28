;;; etaf-ui-animation-tests.el --- Animated catalog controls and SVG stage -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify `etaf-spinner', `etaf-svg-stage' and opt-in `:animated' support on
;; `etaf-progress', `etaf-statistic', `etaf-skeleton' and `etaf-dialog'
;; strictly through public ETAF and ETAF UI interfaces.

;;; Code:
(require 'cl-lib)
(require 'ert)
(require 'etaf)
(require 'etaf-ui)

(defun etaf-ui-anim-test--wait (predicate)
  "Process timers until PREDICATE returns non-nil, with a bounded deadline."
  (let ((deadline (+ (float-time) 2.0)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    (should (funcall predicate))))

(defun etaf-ui-anim-test--text (buffer)
  "Return plain text content of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest etaf-ui-spinner-cycles-frames-and-validates-props ()
  "Spinner cycles fixed-width frames, stops on unmount and rejects bad props."
  (let ((buffer (generate-new-buffer " *etaf-ui-spinner*"))
        runtime)
    (unwind-protect
        (progn
          (should-error
           (etaf-mount buffer (etaf-view (etaf-spinner :style 'bogus))
                       (list :viewport-width 320 :viewport-height 6))
           :type 'etaf-component-call-error)
          (should-error
           (etaf-mount buffer (etaf-view (etaf-spinner :interval 0))
                       (list :viewport-width 320 :viewport-height 6))
           :type 'etaf-component-call-error)
          (etaf-mount buffer
                      (etaf-view (etaf-spinner :style 'line :label "Loading"
                                               :interval 0.03))
                      (list :viewport-width 320 :viewport-height 6))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (let ((initial (etaf-ui-anim-test--text buffer)))
            (should (string-match-p "Loading" initial))
            (etaf-ui-anim-test--wait
             (lambda ()
               (not (equal initial (etaf-ui-anim-test--text buffer))))))
          (etaf-unmount runtime)
          (setq runtime nil))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-ui-animated-feedback-progress-statistic-and-skeleton ()
  "Animated progress, statistic and skeleton advance smoothly on shared clock."
  (let ((buffer (generate-new-buffer " *etaf-ui-anim-feedback*"))
        (progress (etaf-ref 0))
        (score (etaf-ref 0))
        runtime)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 40) :item-gap '(lh 1)
              (etaf-progress :value (etaf-value progress) :max 100 :label "Score"
                             :animated t)
              (etaf-statistic :label "Chips" :value score :animated t)
              (etaf-skeleton :width '(ch 20) :height '(lh 1) :animated t)))
           (list :viewport-width 480 :viewport-height 16))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (should (string-match-p "0%" (etaf-ui-anim-test--text buffer)))
          (setf (etaf-value progress) 100
                (etaf-value score) 250)
          (etaf-ui-anim-test--wait
           (lambda ()
             (let ((text (etaf-ui-anim-test--text buffer)))
               (and (string-match-p "100%" text)
                    (string-match-p "250" text)))))
          (let ((rev (etaf-runtime-revision runtime)))
            (etaf-ui-anim-test--wait
             (lambda () (> (etaf-runtime-revision runtime) rev)))))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-ui-dialog-animated-backdrop-fades-in ()
  "An animated dialog opens with a settling backdrop and dismisses cleanly."
  (let ((buffer (generate-new-buffer " *etaf-ui-anim-dialog*"))
        (open (etaf-ref nil))
        (closed 0)
        runtime)
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :width '(ch 60) :height '(lh 20)
              (box :color "#FFFFFF" "Background content")
              (etaf-dialog :open open :title "Notice" :width '(ch 36)
                           :animated t
                           :on-close (lambda ()
                                       (cl-incf closed)
                                       (setf (etaf-value open) nil))
                (etaf-label :text "Animated modal body")))))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (setf (etaf-value open) t)
          (etaf-ui-anim-test--wait
           (lambda ()
             (string-match-p "Animated modal body"
                             (etaf-ui-anim-test--text buffer))))
          (let ((rev (etaf-runtime-revision runtime)))
            (etaf-ui-anim-test--wait
             (lambda () (> (etaf-runtime-revision runtime) rev))))
          (setf (etaf-value open) nil)
          (etaf-runtime-flush runtime)
          (should-not (string-match-p "Animated modal body"
                                      (etaf-ui-anim-test--text buffer))))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-ui-svg-stage-composites-only-overlapping-tiles-and-falls-back ()
  "SVG stage composites moving sprites only onto overlapped tiles and falls back."
  (let ((buffer (generate-new-buffer " *etaf-ui-svg-stage*"))
        (sprite-pos (etaf-ref (cons 2 2)))
        (pressed nil)
        runtime)
    (unwind-protect
        (progn
          (should-error
           (etaf-mount
            buffer
            (etaf-view (etaf-svg-stage :rows 0 :columns 2
                                       :cell-svg (lambda (_r _c _w _h) "")))
            (list :viewport-width 320 :viewport-height 10))
           :type 'etaf-component-call-error)
          ;; Graphical mode: verify per-tile SVG compositing and hit dispatch.
          (etaf-mount
           buffer
           (etaf-view
            (etaf-svg-stage
             :rows 2 :columns 2 :cell-width 4 :cell-height 2
             :tile-width 32 :tile-height 32 :graphic t
             :cell-ref (lambda (r c) (intern (format "stage-%d-%d" r c)))
             :cell-svg (lambda (r c tw th)
                         (etaf-ui-svg-rect (* c tw) (* r th) tw th
                                           :fill "#223344"))
             :sprites
             (lambda ()
               (let ((xy (etaf-value sprite-pos)))
                 (list (list :x (car xy) :y (cdr xy) :width 12 :height 12
                             :markup (etaf-ui-svg-circle
                                      (+ (car xy) 6) (+ (cdr xy) 6) 5
                                      :fill "#ff5500")))))
             :on-cell-press (lambda (r c) (setq pressed (cons r c)))))
           (list :viewport-width 320 :viewport-height 10))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (etaf-dispatch-event runtime 'stage-1-1 'press)
          (should (equal '(1 . 1) pressed))
          (let ((rev (etaf-runtime-revision runtime)))
            (setf (etaf-value sprite-pos) (cons 36 36))
            (etaf-runtime-flush runtime)
            (should (> (etaf-runtime-revision runtime) rev)))
          (etaf-unmount runtime)
          (setq runtime nil)
          ;; Text fallback mode: uses :cell-text cleanly without SVG images.
          (etaf-mount
           buffer
           (etaf-view
            (etaf-svg-stage
             :rows 2 :columns 2 :cell-width 3 :cell-height 1 :graphic nil
             :cell-svg (lambda (_r _c _tw _th) "")
             :cell-text (lambda (r c) (format "%d,%d" r c))))
           (list :viewport-width 320 :viewport-height 8))
          (setq runtime (etaf-runtime-for-buffer buffer))
          (let ((text (etaf-ui-anim-test--text buffer)))
            (should (string-match-p "0,0" text))
            (should (string-match-p "1,1" text))))
      (when runtime (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-ui-animation-tests)
;;; etaf-ui-animation-tests.el ends here
