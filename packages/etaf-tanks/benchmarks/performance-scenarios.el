;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- Iron Tide input-to-publication workloads
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Every workload fights the final bundled stage on hard difficulty, so the
;; most enemies, shells and terrain are live while input is measured.
;;; Code:
(require 'etaf-tanks)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defconst etaf-tanks-benchmark--stage
  (expand-file-name "../native/godot/stages/20.txt" (file-name-directory (or load-file-name buffer-file-name)))
  "The final and most crowded bundled campaign stage.")

(defun etaf-tanks-benchmark--battle (session counter)
  "Keep SESSION in a live, unpaused battle; return non-nil once it is.
A battle is live while its phase is play, the player's tank is on the
field and the base stands; after the base falls, input is ignored until
the lost phase ends and a new battle begins.  COUNTER is a one-element
list numbering the battles begun, which seeds them."
  (let ((phase (etaf-gamekit-view session :phase)) (hud (etaf-gamekit-view session :hud)))
    (cond
     ((member phase '("menu" "cleared" "over"))
      (etaf-gamekit-action session "begin"
                           (list :map (with-temp-buffer (insert-file-contents etaf-tanks-benchmark--stage)
                                                        (buffer-string))
                                 :stage 20 :difficulty "hard" :seed (cl-incf (car counter))))
      nil)
     ((eq t (etaf-gamekit-view session :paused)) (etaf-gamekit-action session "pause") nil)
     (t (and (equal phase "play") (eq t (plist-get hud :alive)) (eq t (plist-get hud :base)))))))

(defun etaf-tanks-benchmark--images (runtime buffer)
  "Read the image displays actually published inside the battlefield."
  (when-let* ((bounds (etaf-host-ref-bounds runtime 'tanks-board)))
    (with-current-buffer buffer
      (let ((position (car bounds)) (end (cdr bounds)) images)
        (while (< position end)
          (let* ((display (get-text-property position 'display))
                 (image (cond ((eq (car-safe display) 'image) display)
                              ((listp display)
                               (cl-find-if (lambda (part) (eq (car-safe part) 'image)) display)))))
            (when image (push image images)))
          (setq position (next-single-property-change position 'display nil end)))
        (nreverse images)))))

(defun etaf-tanks-benchmark--fixture (mode operation)
  "Create one independent live battle for MODE and measured OPERATION."
  (let* ((etaf-tanks-appearance 'light) (session (etaf-tanks-open))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
         (counter (list 0)) before expected fitted)
    (list
     :buffer (etaf-gamekit-buffer session)
     :ready (lambda ()
              (unless fitted
                (if (eq mode 'batch) (etaf-runtime-refit runtime 1300 50)
                  (etaf-refit runtime (selected-window)))
                (setq fitted t))
              (and (eq (etaf-gamekit-status session) 'ready)
                   (etaf-host-ref-size runtime 'tanks-board)
                   (etaf-tanks-benchmark--battle session counter)))
     :invoke
     (lambda (_index)
       (pcase operation
         ('theme
          (setq before (plist-get (etaf-runtime-host-props-for runtime 'tanks-theme) :aria-label))
          (etaf-dispatch-event runtime 'tanks-theme 'press))
         ('pause
          (setq expected (if (eq t (etaf-gamekit-view session :paused)) :false t))
          (etaf-dispatch-event runtime 'tanks-pause 'press))
         ('resize
          (setq expected (if (= (car (etaf-runtime-viewport runtime)) 900) 1300 900))
          (etaf-runtime-refit runtime expected 50))))
     :settled
     (lambda ()
       (and (eq (etaf-gamekit-status session) 'ready)
            (pcase operation
              ('theme (not (equal before (plist-get (etaf-runtime-host-props-for runtime 'tanks-theme) :aria-label))))
              ('pause (eq expected (etaf-gamekit-view session :paused)))
              ('resize (= expected (car (etaf-runtime-viewport runtime)))))))
     :verify (lambda ()
               (and (not (etaf-gamekit-last-error session))
                    (etaf-host-ref-size runtime 'tanks-board) t))
     :outcome (lambda () (list :operation (symbol-name operation) :battles (car counter)
                              :board (let ((size (etaf-host-ref-size runtime 'tanks-board)))
                                       (vector (car size) (cdr size)))))
     :cleanup (lambda () (etaf-tanks-close session)))))

(dolist (case '((theme 50 "Repaint the live final battlefield and its controls in the other palette")
                (pause 50 "Pause or resume the final battle through its rendered control")
                (resize 50 "Refit the interface and rescale the live battlefield")))
  (let ((operation (car case)))
    (taf-benchmark-register (format "etaf-tanks.%s" operation)
      :version 3 :modes '(batch gui) :isolation 'series :impact 'subtree
      :budget-ms (cadr case) :description (caddr case)
      :setup (lambda (mode) (etaf-tanks-benchmark--fixture mode operation)))))

(defun etaf-tanks-benchmark--keys (operation)
  "Measure real command-loop input during the final stage's live battle.
Driving and aiming alternate west and east, so every sample turns the tank
and it keeps a lane near its spawn; every sample must also change the
published battlefield image.  From its second sample on, driving while
firing must also have seen the battlefield repainted at least twice while
the tank moved; one sample can settle on its first repaint.  Finished
battles are renewed through public actions in readiness, outside the
measurement."
  (unless (display-graphic-p)
    (error "Native-input workloads require a graphical display"))
  (let* ((session (etaf-tanks-open))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
         (counter (list 0)) (invoked 0) east expected expected-shots before-image key fitted
         paint-observer paint-installed painted-at painted-images paint-gaps)
    (cl-labels
        ((actor (field) (plist-get (etaf-gamekit-view session :actor) field))
         (canvas () (etaf-tanks-benchmark--images runtime (etaf-gamekit-buffer session)))
         (redrawing (_window)
           (if (and (eq t (actor :moving)) (eq :false (etaf-gamekit-view session :paused)))
               (let ((images (canvas)) (now (float-time)))
                 (unless (equal images painted-images)
                   (when painted-at (push (* 1000 (- now painted-at)) paint-gaps))
                   (setq painted-at now painted-images images)))
             (setq painted-at nil painted-images nil))))
      (setq paint-observer #'redrawing)
      (list
       :buffer (etaf-gamekit-buffer session)
       :environment (lambda () (list :input "Emacs command loop" :simulation "live 60 Hz Godot"
                                    :stage "20 (final) on hard"
                                    :frame (let ((frame (etaf-gamekit-view session :frame)))
                                             (format "%s device pixels per block, %s per line"
                                                     (plist-get frame :block) (plist-get frame :line)))
                                    :completion "acknowledged state plus a changed battlefield image"
                                    :renewal "new battle after a cleared or lost stage"
                                    :paint-observer (if (eq operation 'drive-fire)
                                                        "before redisplay during player motion; includes harness overhead"
                                                      "none")))
       :ready
       (lambda ()
         (when (memq (etaf-gamekit-status session) '(failed closed))
           (error "Battle fixture failed: %s" (etaf-gamekit-last-error session)))
         (unless fitted (etaf-refit runtime (selected-window)) (setq fitted t))
         (and (eq (etaf-gamekit-status session) 'ready)
              (etaf-host-ref-size runtime 'tanks-board)
              (etaf-tanks-benchmark--battle session counter)
              (or (memq operation '(drive aim)) (eq t (actor :can_fire)))))
       :prepare (lambda ()
                  (etaf-focus runtime 'tanks-board)
                  (when (and (eq operation 'drive-fire) (not paint-installed))
                    (with-current-buffer (etaf-gamekit-buffer session)
                      (add-hook 'pre-redisplay-functions paint-observer nil t))
                    (setq paint-installed t)))
       :invoke
       (lambda (_index)
         ;; Turn away from the current facing so every sample changes it,
         ;; including after a respawn.
         (setq before-image (canvas) east (not (equal (actor :facing) "e")))
         (cl-incf invoked)
         (pcase operation
           ('drive (setq key (if east "<right>" "<left>") expected (if east "e" "w")))
           ('drive-fire (setq key (if east "<right> f" "<left> f") expected (if east "e" "w")
                              expected-shots (1+ (actor :shots))))
           ('aim (setq key (if east "S-<right>" "S-<left>") expected (if east "e" "w")))
           ('fire (setq key "f" expected-shots (1+ (actor :shots)))))
         (execute-kbd-macro (kbd key)))
       :settled
       (lambda ()
         (when-let* ((failure (etaf-gamekit-last-error session)))
           (error "Native input rejected: %s" failure))
         (and (eq (etaf-gamekit-status session) 'ready)
              (not (equal before-image (canvas)))
              (pcase operation
                ((or 'drive 'aim) (equal expected (actor :facing)))
                ('drive-fire (and (equal expected (actor :facing)) (= expected-shots (actor :shots))))
                ('fire (= expected-shots (actor :shots))))))
       :verify (lambda ()
                 (if (and (eq operation 'drive-fire) (> invoked 1) (null paint-gaps))
                     "No continuous redraw evidence"
                   (and (not (etaf-gamekit-last-error session))
                        (etaf-host-ref-size runtime 'tanks-board) t)))
       :outcome (lambda () (list :key key :battles (car counter)
                                :position (vector (actor :x) (actor :y)) :shots (actor :shots)
                                :lives (plist-get (etaf-gamekit-view session :hud) :lives)
                                :moving-redraw-gaps-ms (vconcat (reverse paint-gaps))))
       :cleanup (lambda ()
                  (when (buffer-live-p (etaf-gamekit-buffer session))
                    (with-current-buffer (etaf-gamekit-buffer session)
                      (remove-hook 'pre-redisplay-functions paint-observer t)))
                  (etaf-tanks-close session))))))

(dolist (case '((drive "Drive key to a changed battlefield image in the final live battle")
                (aim "Repeated turning keys while enemies and shells keep moving")
                (fire "Repeated loaded shots through F and visible projectiles")
                (drive-fire "Continuous driving, alternating turns and simultaneous fire")))
  (let ((operation (car case)))
    (taf-benchmark-register (format "etaf-tanks.keys.%s" operation)
      :version 6 :modes '(gui) :isolation 'series :impact 'subtree
      :budget-ms 50 :description (cadr case)
      :setup (lambda (_mode) (etaf-tanks-benchmark--keys operation)))))

(provide 'etaf-tanks-performance-scenarios)
;;; performance-scenarios.el ends here
