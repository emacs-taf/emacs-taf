;;; etaf-ui-window-resize-tests.el --- Catalog window resizing -*- lexical-binding: t; -*-

;;; Commentary:
;; Public mounting, geometry, painted output and native input remain consistent.
;;; Code:
(require 'ert)
(require 'etaf-ui)
(require 'ebox)

(defun etaf-ui-resize-test--view (width height activate)
  "Return a catalog window with controlled WIDTH, HEIGHT and ACTIVATE."
  (etaf-view
   (box :width '(px 720) :height '(lh 30) :position 'relative
        :background-color "#EAF0F6"
     (etaf-window :id "window" :ref 'window :title "Inspector"
                  :chrome-ref 'title :x '(px 16) :y '(lh 2)
                  :width width :height height
                  :resize-refs '((left . left) (right . right)
                                 (top . top) (bottom . bottom)
                                 (top-left . top-left) (top-right . top-right)
                                 (bottom-left . bottom-left) (bottom-right . bottom-right))
                  :on-resize (lambda (_edge _gesture) nil)
                  :on-close activate
       (box :width '(px 480) :height '(lh 6) :wrap-mode 'none :overflow 'hidden
         (text "Fixed content: 0123456789 abcdefghijklmnopqrstuvwxyz\nSecond line."))))))

(defun etaf-ui-resize-test--fresh (buffer view)
  "Compare BUFFER's painted text and native properties with a fresh mount of VIEW."
  (let ((fresh (generate-new-buffer " *catalog resize fresh*")))
    (unwind-protect
        (let ((actual (with-current-buffer buffer (buffer-string)))
              (expected (progn (etaf-mount fresh view)
                               (with-current-buffer fresh (buffer-string)))))
          (should (equal (substring-no-properties actual) (substring-no-properties expected)))
          (dotimes (index (length actual))
            (dolist (property '(display face font-lock-face pointer help-echo mouse-face))
              (should (equal (get-text-property index property actual)
                             (get-text-property index property expected))))))
      (when-let* ((runtime (etaf-runtime-for-buffer fresh))) (etaf-unmount runtime))
      (kill-buffer fresh))))

(ert-deftest etaf-ui-window-resize-keeps-chrome-and-input ()
  "A real window resizes with current title, corners, geometry and action targets."
  (let ((buffer (generate-new-buffer " *catalog retained resize*"))
        (width (etaf-ref '(px 320) :test #'equal))
        (height (etaf-ref '(lh 12) :test #'equal)) (clicks 0))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-ui-resize-test--view width height
                              (lambda () (setq clicks (1+ clicks)))))
          (let* ((runtime (etaf-runtime-for-buffer buffer))
                 (close (car (cl-find-if
                              (lambda (entry) (equal (plist-get (cdr entry) :aria-label) "Close"))
                              (etaf-runtime-host-props-entries runtime)))))
            (dolist (size '((352 14) (280 10) (440 16) (320 12)))
              (let ((revision (etaf-runtime-revision runtime)))
                (etaf-batch
                  (etaf-set-value width (list 'px (car size)))
                  (etaf-set-value height (list 'lh (cadr size))))
                (should (= (1+ revision) (etaf-runtime-flush runtime))))
              (should (equal (plist-get (etaf-runtime-host-props-for runtime 'window) :width)
                             (etaf-value width)))
              (dolist (reference '(title left right top bottom top-left top-right bottom-left bottom-right))
                (should (etaf-host-ref-position runtime reference)))
              (etaf-ui-resize-test--fresh
               buffer (etaf-ui-resize-test--view width height #'ignore))
              (etaf-dispatch-event runtime close 'press))
            (should (= clicks 4))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-ui-window-resize-example-uses-controlled-handles ()
  "The real catalog example accepts native gesture phases and restores on quit."
  (let ((buffer (generate-new-buffer " *catalog resize example*")))
    (unwind-protect
        (progn
          (should (eq buffer (etaf-ui-window-resize-open buffer)))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-dispatch-event runtime 'resize-bottom-right 'drag '(:phase start :delta (0 . 0)) t)
            (etaf-dispatch-event runtime 'resize-bottom-right 'drag '(:phase move :delta (20 . 2)) t)
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'resize-window) :width) '(px 380)))
            (etaf-dispatch-event runtime 'resize-bottom-right 'drag '(:phase cancel :reason quit :delta (20 . 2)) t)
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'resize-window) :width) '(px 360)))
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'resize-window) :height) '(lh 12)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-ui-window-resize-tests)
;;; etaf-ui-window-resize-tests.el ends here
