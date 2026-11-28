;;; etaf-ui-window-tests.el --- Controlled panel and window contracts -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf-ui)

(ert-deftest etaf-ui-window-reactive-geometry-preserves-content-and-input ()
  "Move, resize and layer changes preserve the controlled content and input."
  (let ((buffer (generate-new-buffer " *etaf-ui-window-reactive*"))
        (x (etaf-ref '(px 4))) (y (etaf-ref '(lh 1)))
        (width (etaf-ref '(px 260))) (height (etaf-ref '(lh 12)))
        (z (etaf-ref 1)) (checked (etaf-ref nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window :title "Inspector" :ref 'window :x x :y y
                         :width width :height height :z-index z
                         (etaf-checkbox :ref 'toggle :label "Preserved" :bind checked))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (original (etaf-runtime-host-props-for runtime 'window)))
            (etaf-dispatch-event runtime 'toggle 'press)
            (should (etaf-value checked))
            (dolist (rectangle '((44 3 320 14 2) (12 2 240 10 3)))
              (progn
                (etaf-set-value x (list 'px (nth 0 rectangle)))
                (etaf-set-value y (list 'lh (nth 1 rectangle)))
                (etaf-set-value width (list 'px (nth 2 rectangle)))
                (etaf-set-value height (list 'lh (nth 3 rectangle)))
                (etaf-set-value z (nth 4 rectangle)))
              (etaf-runtime-flush runtime)
              (let ((props (etaf-runtime-host-props-for runtime 'window)))
                (should (equal (plist-get props :left) (etaf-value x)))
                (should (equal (plist-get props :top) (etaf-value y)))
                (should (equal (plist-get props :width) (etaf-value width)))
                (should (equal (plist-get props :height) (etaf-value height)))
                (should (= (plist-get props :z-index) (etaf-value z))))
              (should (etaf-host-ref-position runtime 'toggle))
              (should (etaf-value checked))
              (with-current-buffer buffer
                (should (string-match-p "Preserved" (buffer-string)))))
            (should (equal (plist-get original :left) '(px 4)))
            (etaf-dispatch-event runtime 'toggle 'press)
            (should-not (etaf-value checked))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-window-keeps-geometry-and-mode-controlled ()
  "Window geometry is projected from caller refs and mode only changes content."
  (let ((buffer-name " *etaf-ui-window-controlled-test*")
        (x (etaf-ref '(px 4)))
        (y (etaf-ref '(lh 1)))
        (mode (etaf-ref 'normal)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-window :title "Inspector" :ref 'window
                         :chrome-ref 'window-chrome
                         :x x :y y :width '(px 260) :height '(lh 12)
                         :mode mode
                         (etaf-label :text "Body"))))
          (let* ((runtime (etaf-runtime-for-buffer buffer-name))
                 (properties (etaf-runtime-host-props-for runtime 'window)))
            (should (equal (plist-get properties :position) 'absolute))
            (should (equal (plist-get properties :left) (etaf-value x)))
            (should (equal (plist-get properties :top) (etaf-value y)))
            (should (string-match-p "Body"
                                    (with-current-buffer buffer-name
                                      (buffer-string))))
            (setf (etaf-value mode) 'maximized)
            (should (string-match-p
                     "etaf-window maximized"
                     (plist-get (etaf-runtime-host-props-for runtime 'window) :class)))
            (should (string-match-p
                     "etaf-window-chrome maximized"
                     (plist-get (etaf-runtime-host-props-for runtime 'window-chrome)
                                :class)))
            (setf (etaf-value mode) 'minimized)
            (should-not (string-match-p "Body"
                                        (with-current-buffer buffer-name
                                          (buffer-string))))
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'window)
                                      :left)
                           (etaf-value x)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-window-forwards-chrome-and-resize-gestures ()
  "Title and handle gestures reach caller callbacks with their public payloads."
  (let ((buffer-name " *etaf-ui-window-gesture-test*")
        moves resizes actions)
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-window :title "Inspector" :ref 'window
                         :chrome-ref 'window-chrome
                         :resize-refs '((right . window-resize-right))
                         :width '(px 260) :height '(lh 12)
                         :on-move (lambda (gesture) (push gesture moves))
                         :on-resize (lambda (edge gesture)
                                      (push (list edge gesture) resizes))
                         :on-close (lambda () (push 'close actions))
                         (etaf-label :text "Body"))))
          (let ((runtime (etaf-runtime-for-buffer buffer-name)))
            (etaf-dispatch-event runtime 'window-chrome 'drag
                                 '(:phase move :delta (3 . 4)) t)
            (etaf-dispatch-event runtime 'window-resize-right 'drag
                                 '(:phase end :delta (8 . 0)) t)
            (etaf-dispatch-event runtime
                                 ;; Close is the final generated Button in the
                                 ;; chrome and is intentionally tested through
                                 ;; its semantic label lookup below.
                                 (car (cl-find-if
                                       (lambda (entry)
                                         (equal "Close"
                                                (plist-get (cdr entry) :aria-label)))
                                       (etaf-runtime-host-props-entries runtime)))
                                 'press)
            (should (= (length moves) 1))
            (should (equal (caar resizes) 'right))
            (should (equal (plist-get (cadar resizes) :phase) 'end))
            (should (equal actions '(close)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-window-moves-and-resizes-from-keys-inside-it ()
  "Focus entering a window activates it; M-arrows move it, M-S-arrows resize it."
  (let ((buffer-name " *etaf-ui-window-keys-test*")
        moves resizes (focused 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer-name
           (etaf-view
            (etaf-window :title "Inspector" :width '(px 260) :height '(lh 12)
                         :on-move (lambda (gesture) (push gesture moves))
                         :on-resize (lambda (edge gesture)
                                      (push (cons edge gesture) resizes))
                         :on-focus (lambda () (cl-incf focused))
                         (etaf-button :label "Body" :ref 'body
                                      :on-press #'ignore))))
          (with-current-buffer buffer-name
            (etaf-focus (etaf-runtime-for-buffer buffer-name) 'body)
            (should (= focused 1))
            (dolist (key '("M-<right>" "M-S-<down>" "M-S-<left>"))
              (call-interactively (key-binding (kbd key) t)))
            (let ((move-end (cl-find 'end moves
                                     :key (lambda (g) (plist-get g :phase)))))
              (should (> (car (plist-get move-end :delta)) 0))
              (should (plist-get move-end :keyboard)))
            (let ((ends (cl-remove-if-not
                         (lambda (entry) (eq (plist-get (cdr entry) :phase) 'end))
                         (reverse resizes))))
              (should (equal (mapcar #'car ends) '(bottom right)))
              (should (> (cdr (plist-get (cdar ends) :delta)) 0))
              (should (< (car (plist-get (cdadr ends) :delta)) 0)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer-name)))
        (etaf-unmount runtime))
      (when-let* ((buffer (get-buffer buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-resizable-panel-rejects-unknown-edge ()
  "Resize edge input is checked before a Component is mounted."
  (should-error
   (etaf-mount " *etaf-ui-window-invalid-test*"
               (etaf-view
                (etaf-resizable-panel :resize-edges '(diagonal))))
   :type 'etaf-component-call-error)
  (when-let* ((buffer (get-buffer " *etaf-ui-window-invalid-test*")))
    (kill-buffer buffer)))

(etaf-define-component etaf-ui-window-test-viewport (&key seen)
  "Record the Component subtree's viewport into the cons cell SEEN."  :setup
  (progn
    (etaf-watch-effect
     (lambda () (setcar seen (etaf-viewport))))
    nil)
  :view (text "body"))

(ert-deftest etaf-ui-window-body-reads-the-content-region ()
  "Window body content reads the window's content box as its viewport."
  (let ((buffer (generate-new-buffer " *etaf-ui-window-viewport*"))
        (height (etaf-ref '(lh 12)))
        (seen (cons nil nil)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window :title "Viewport" :width '(px 260) :height height
                         (etaf-ui-window-test-viewport :seen seen))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (should (consp (car seen)))
            (should (< 0 (car (car seen)) 260))
            (should (= (cdr (car seen)) 11))
            (etaf-set-value height '(lh 20))
            (etaf-runtime-flush runtime)
            (should (= (cdr (car seen)) 19))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-window-full-bleed-body-reaches-the-frame-edges ()
  "A full-bleed window gives its body the edge cells of its handles."
  (dolist (sample '((t 11) (nil 10)))
    (let ((buffer (generate-new-buffer " *etaf-ui-window-bleed*"))
          (seen (cons nil nil)))
      (unwind-protect
          (progn
            (etaf-mount
             buffer
             (etaf-view
              (etaf-window :title "Bleed" :width '(px 260) :height '(lh 12)
                           :full-bleed (car sample)
                           :resize-refs '((bottom-right . bleed-bottom-right))
                           :on-resize (lambda (_edge _gesture) nil)
                           (etaf-ui-window-test-viewport :seen seen))))
            (should (= (cdr (car seen)) (cadr sample))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-ui-window-full-bleed-handles-own-edge-input ()
  "All eight full-bleed handles remain painted targets after geometry changes."
  (let ((buffer (generate-new-buffer " *etaf-ui-window-edge-input*"))
        (width (etaf-ref '(px 360))) (height (etaf-ref '(lh 12)))
        (edges '(left right top bottom top-left top-right bottom-left bottom-right)))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window :title "Edges" :width width :height height :full-bleed t
                         :on-focus #'ignore :on-resize (lambda (_edge _gesture) nil)
                         :resize-refs (mapcar (lambda (edge) (cons edge edge)) edges)
                         (box :padding '((lh 0) (px 8))
                              (etaf-button :ref 'body-action :label "Action" :pointer 'hand
                                           :on-press #'ignore)))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (dolist (size '((360 12) (420 16) (260 8)))
              (etaf-set-value width (list 'px (car size)))
              (etaf-set-value height (list 'lh (cadr size)))
              (etaf-runtime-flush runtime)
              (with-current-buffer buffer
                (dolist (edge edges)
                  (let ((position (etaf-host-ref-position runtime edge)))
                    (should position)
                    (should (eq edge (etaf-host-ref-at runtime position)))
                    (should (eq (get-text-property position 'pointer)
                                (cond ((memq edge '(left right)) 'hdrag)
                                      ((memq edge '(top bottom)) 'vdrag)
                                      (t 'nhdrag))))))
                (should (eq 'hand (get-text-property
                                  (etaf-host-ref-position runtime 'body-action) 'pointer)))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-window-full-bleed-handles-leave-the-body-painted ()
  "A full-bleed handle is a hit surface: the body's own paint stays visible."
  (let* ((buffer (generate-new-buffer " *etaf-ui-window-bleed-paint*"))
         (width (etaf-ref '(px 360))) (height (etaf-ref '(lh 12)))
         (edges '(left right bottom))
         (background
          (lambda (position)
            (let ((face (get-text-property position 'face)))
              (cond ((and (listp face) (plist-get face :background))
                     (plist-get face :background))
                    ((listp face)
                     (cl-some (lambda (attributes)
                                (and (listp attributes)
                                     (plist-get attributes :background)))
                              face))
                    ((and (symbolp face) face)
                     (face-attribute face :background nil t)))))))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (etaf-window :title "Paint" :width width :height height
                         :full-bleed t
                         :on-resize (lambda (_edge _gesture) nil)
                         :resize-refs (mapcar (lambda (edge) (cons edge edge)) edges)
                         (box :width 'stretch :height 'stretch
                              :background-color "#ff0000"
                              (text "X")))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (with-current-buffer buffer
              (dolist (edge edges)
                (let ((position (etaf-host-ref-position runtime edge)))
                  (should position)
                  ;; The handle still owns the pointer...
                  (should (get-text-property position 'pointer))
                  ;; ...while the body's paint shows through it.
                  (should (equal (color-values (funcall background position))
                                 (color-values "#ff0000"))))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
        (etaf-unmount runtime))
      (kill-buffer buffer))))

;;; etaf-ui-window-tests.el ends here
