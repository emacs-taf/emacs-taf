;;; etaf-ui-range-tests.el --- Public API acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; Test supported package inputs, outputs, errors and lifecycle.
;; Internal implementation details are outside this contract.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'etaf-ui)

(defmacro etaf-ui-range-test--with-range (clause &rest body)
  "Mount an `etaf-range' with CLAUSE's props and bind its runtime.
CLAUSE is (RUNTIME PROP VALUE ...); RUNTIME receives (BUFFER . RUNTIME)."
  (declare (indent 1) (debug (form body)))
  (let ((runtime (car clause))
        (props (cdr clause)))
    `(let ((buffer (generate-new-buffer " *etaf-ui-range*")))
       (unwind-protect
           (save-window-excursion
             (delete-other-windows)
             (set-window-buffer (selected-window) buffer)
             (etaf-mount buffer (lambda () (etaf-view (flex :flex-direction 'column :align-items 'stretch
                                                   :width '(vw 100) :height '(vh 100)
                                                   (etaf-range ,@props))))
                         '(:viewport-width 240 :viewport-height 8))
             (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
             (let ((,runtime (cons buffer (etaf-runtime-for-buffer buffer))))
               ,@body))
         (when-let* ((live (etaf-runtime-for-buffer buffer)))
           (etaf-unmount live))
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun etaf-ui-range-test--pixels (entry host)
  "Return HOST's painted (LEFT WIDTH) inside ENTRY's mounted buffer."
  (pcase-let* ((`(,buffer . ,runtime) entry)
               (bounds (etaf-host-ref-bounds runtime host)))
    (should bounds)
    (with-current-buffer buffer
      (let ((start (car bounds)) (end (cdr bounds)))
        (list (etaf-string-pixel-width
               (buffer-substring (save-excursion (goto-char start)
                                                 (line-beginning-position))
                                 start))
              (etaf-string-pixel-width (buffer-substring start end)))))))

(defun etaf-ui-range-test--dispatch (entry host kind ratio &optional phase)
  "Dispatch KIND for HOST in ENTRY at RATIO, with drag PHASE when given."
  (pcase-let* ((`(,buffer . ,runtime) entry)
               (`(,left ,width) (etaf-ui-range-test--pixels entry host))
               (x (+ left (* ratio width)))
               (payload (list :phase phase :host-ref host :window (selected-window)
                              :buffer buffer :position (cons x 0))))
    (etaf-dispatch-event runtime host kind payload t)))

(ert-deftest etaf-ui-range-registers-track-and-fill-hosts ()
  "A mounted Range registers its Track and Fill Hosts for retained updates.
Painted proportions need a graphical frame and are checked by the GUI pass;
this batch contract covers the Host identities every retained update needs."
  (etaf-ui-range-test--with-range (entry :value 25 :ref 'range-track :fill-ref 'range-fill)
    (pcase-let* ((`(,buffer . ,runtime) entry)
                 (refs (mapcar #'car (etaf-runtime-host-props-entries runtime))))
      (should (etaf-host-ref-bounds runtime 'range-track))
      (should (memq 'range-fill refs)))))

(ert-deftest etaf-ui-range-bar-height-changes-ink-without-changing-geometry ()
  "Thickness changes graphical bar paint, never row size or retained widths."
  (let (displays)
    (dolist (height '(1 10 40 90 100))
      (let ((value (etaf-ref 50)))
        (etaf-ui-range-test--with-range
            (entry :value value :bar-height height :ref 'range-track :fill-ref 'range-fill)
          (let* ((runtime (cdr entry))
                 (track-size (etaf-host-ref-size runtime 'range-track))
                 (fill-size (etaf-host-ref-size runtime 'range-fill)))
            (should (equal track-size '(240 . 1)))
            (should (equal fill-size '(120 . 1)))
            (with-current-buffer (car entry)
              (let ((position (etaf-host-ref-position runtime 'range-fill)))
                (let ((display (get-text-property position 'display)))
                  (push display displays)
                  (when (and (display-graphic-p) (image-type-available-p 'svg))
                    (let* ((image (assq 'image display))
                           (size (and image (image-size image t))))
                      (should size)
                      (should (= (cdr size) (frame-char-height))))))
                (when (display-graphic-p)
                  (redisplay t)
                  (save-excursion
                    (goto-char position)
                    (should (= (line-pixel-height) (frame-char-height)))))))
            (etaf-set-value value 75)
            (let ((next-size (etaf-host-ref-size runtime 'range-fill)))
              (should (equal next-size '(180 . 1))))
            (dolist (width '(160 480 240))
              (etaf-runtime-refit runtime width 8)
              (let ((size (etaf-host-ref-size runtime 'range-fill))
                    (pixels (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
                (should (equal size (cons (/ (* width 3) 4) 1)))
                (should (= pixels (* width 0.75)))))))))
    (if (and (display-graphic-p) (image-type-available-p 'svg))
        (progn
          (should (cl-every #'identity displays))
          (should (= (length (delete-dups displays)) 5)))
      ;; Text-only frames keep the ordinary rule; fractional ink is graphical.
      (should (equal displays '(nil nil nil nil nil))))))

(ert-deftest etaf-ui-range-fill-moves-through-retained-geometry ()
  "A caller moves the Fill in place through ETAF's retained geometry update.
The Fill is an absolutely positioned Host, so a playing position advances
in one geometry commit without re-rendering the View."
  (etaf-ui-range-test--with-range (entry :value 25 :ref 'range-track :fill-ref 'range-fill)
    (pcase-let* ((`(,buffer . ,runtime) entry)
                 (before (cadr (etaf-ui-range-test--pixels entry 'range-fill)))
                 (generation (etaf-runtime-revision runtime)))
      (should before)
      (etaf-runtime-update-host-geometries
       runtime (list (cons 'range-fill (list :width '(% 75)))))
      (etaf-runtime-flush runtime)
      (let ((after (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
        (should (> after before))
        ;; One in-place geometry commit; no re-render precedes it.
        (should (= (etaf-runtime-revision runtime) (1+ generation)))))))

(ert-deftest etaf-ui-range-press-reports-change-and-commit ()
  "A click reports the pointed value through on-change and on-commit."
  (let (events)
    (etaf-ui-range-test--with-range
        (entry :value 0 :ref 'range-track :fill-ref 'range-fill
               :on-change (lambda (value) (push (cons :change value) events))
               :on-commit (lambda (value) (push (cons :commit value) events)))
      (etaf-ui-range-test--dispatch entry 'range-track 'press 0.75)
      (should (= (length events) 2))
      (should (eq (caar events) :commit))
      (should (eq (caadr events) :change))
      (dolist (event events)
        (should (< (abs (- (cdr event) 75)) 1.5))))))

(ert-deftest etaf-ui-range-steps-from-the-keyboard ()
  "Left/Right step a focused range by KEY-STEP; Home/End reach the bounds."
  (let (commits)
    (etaf-ui-range-test--with-range
        (entry :value 40 :max 100 :key-step 5 :ref 'range-track
               :on-commit (lambda (value) (push value commits)))
      (pcase-let ((`(,buffer . ,runtime) entry))
        (with-current-buffer buffer
          (etaf-focus runtime 'range-track)
          (dolist (key '("<right>" "<left>" "<end>" "<home>"))
            (call-interactively (key-binding (kbd key) t)))
          (should (equal (nreverse commits) '(45 35 100 0))))))))

(ert-deftest etaf-ui-range-without-ref-hit-tests-pointer-gestures ()
  "A Range given no :ref still measures its track for an Ebox pointer gesture.
Engine gestures carry no Host reference, so the Range names its own track."
  (let (commits)
    (etaf-ui-range-test--with-range
        (entry :value 0 :on-commit (lambda (value) (push value commits)))
      (pcase-let* ((`(,buffer . ,runtime) entry)
                   (track (etaf-host-ref-at runtime (with-current-buffer buffer
                                                      (point-min))))
                   (`(,left ,width) (etaf-ui-range-test--pixels entry track)))
        (should track)
        (etaf-dispatch-event runtime track 'drag
                             (list :phase 'end :window (selected-window) :buffer buffer
                                   :position (cons (+ left (* 0.5 width)) 0))
                             t)
        (should (= (length commits) 1))
        (should (< (abs (- (car commits) 50)) 1.5))))))

(ert-deftest etaf-ui-range-drag-reports-live-values-and-commits-on-release ()
  "Dragging reports intermediate values, commits at the end and drops a cancel."
  (let ((value (etaf-ref 0)) changes commits handler)
    (etaf-ui-range-test--with-range
        (entry :value value :ref 'range-track :fill-ref 'range-fill
               :on-change (lambda (value) (push value changes))
               :on-commit (lambda (value) (push value commits)))
      (setq handler (plist-get (cdr (assq 'range-track (etaf-runtime-host-props-entries (cdr entry)))) :on-drag))
      (etaf-ui-range-test--dispatch entry 'range-track 'drag 0.25 'start)
      (etaf-ui-range-test--dispatch entry 'range-track 'drag 0.5 'move)
      (etaf-ui-range-test--dispatch entry 'range-track 'drag 0.6 'cancel)
      (should (null commits))
      (etaf-ui-range-test--dispatch entry 'range-track 'drag 0.75 'end)
      (should (= (length changes) 3))
      (should (= (length commits) 1))
      (should (< (abs (- (car (last changes)) 25)) 1.5))
      (should (< (abs (- (car commits) 75)) 1.5))
      (etaf-runtime-flush (cdr entry))
      (should (eq handler (plist-get (cdr (assq 'range-track (etaf-runtime-host-props-entries (cdr entry)))) :on-drag)))
      (let ((before (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
        (etaf-set-value value 20)
        (etaf-runtime-flush (cdr entry))
        (let ((after (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
          (should (< after before))))
      (should (eq handler (plist-get (cdr (assq 'range-track (etaf-runtime-host-props-entries (cdr entry)))) :on-drag)))
      ;; Display-only previews must not leave stale authored values behind:
      ;; a later viewport refit still paints the controlled backend value.
      (etaf-runtime-refit (cdr entry) 320 8)
      (let ((track (cadr (etaf-ui-range-test--pixels entry 'range-track)))
            (fill (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
        (should (< (abs (- (/ (float fill) track) 0.2)) 0.02))))))

(ert-deftest etaf-ui-range-snaps-to-the-step-and-clamps-the-ends ()
  "Pointer values snap to :step and never escape :min..:max."
  (let (reported)
    (etaf-ui-range-test--with-range
        (entry :value 0 :min 0 :max 100 :step 10 :ref 'range-track :fill-ref 'range-fill
               :on-commit (lambda (value) (push value reported)))
      (etaf-ui-range-test--dispatch entry 'range-track 'press 0.46)
      (etaf-ui-range-test--dispatch entry 'range-track 'press 1.0)
      (should (equal reported '(100 50))))))

(ert-deftest etaf-ui-range-disabled-rejects-pointer-events ()
  "A disabled Range dispatches no callback and rejects pointer events."
  (let (reported)
    (etaf-ui-range-test--with-range
        (entry :value 40 :disabled t :ref 'range-track :fill-ref 'range-fill
               :on-change (lambda (value) (push value reported))
               :on-commit (lambda (value) (push value reported)))
      (should-error (etaf-ui-range-test--dispatch entry 'range-track 'press 0.5))
      (should (null reported)))))

(ert-deftest etaf-ui-range-reactive-bound-reproportions-in-place ()
  "A reactive :max re-proportions the Fill without a Component re-render.
A duration source changes when the playing track changes; the Range clamps
with the live bound so its caller never reads the source during render."
  (let* ((maximum (etaf-ref 200))
         (bound (etaf-computed (lambda () (etaf-value maximum)))))
    (etaf-ui-range-test--with-range
        (entry :value 50 :min 0 :max bound :ref 'range-track :fill-ref 'range-fill)
      (pcase-let* ((`(,buffer . ,runtime) entry)
                   (before (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
        (etaf-set-value maximum 100)
        (etaf-runtime-flush runtime)
        (let ((after (cadr (etaf-ui-range-test--pixels entry 'range-fill))))
          (should (< (abs (- after (* 2.0 before))) 4.0)))
      ;; Invalid live bounds reject publication, retaining the last accepted
      ;; picture.  Fixing the source must recover without remounting.
      (let ((accepted (with-current-buffer (car entry) (buffer-string))))
        (should-error (etaf-set-value maximum -1))
        (should (equal-including-properties
                 accepted (with-current-buffer (car entry) (buffer-string))))
        (etaf-set-value maximum nil)
        (etaf-runtime-flush (cdr entry))
        (should (equal '(% 0.0)
                       (plist-get (etaf-runtime-host-props-for
                                   (cdr entry) 'range-fill) :width)))
        (etaf-set-value maximum 200)
        (etaf-runtime-flush (cdr entry))
        (should (< (abs (- (/ (float (cadr (etaf-ui-range-test--pixels entry 'range-fill)))
                             (cadr (etaf-ui-range-test--pixels entry 'range-track)))
                          0.25))
                   0.02)))))))

(ert-deftest etaf-ui-range-validates-its-input ()
  "Invalid numeric props fail before the Range paints."
  (should-error
   (etaf-ui-range-test--with-range (entry :value 5 :min 10 :max 0)
     (ignore entry))))

(provide 'etaf-ui-range-tests)
;;; etaf-ui-range-tests.el ends here
