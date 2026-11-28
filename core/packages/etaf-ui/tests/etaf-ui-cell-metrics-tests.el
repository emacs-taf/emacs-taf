;;; etaf-ui-cell-metrics-tests.el --- Measuring in the canvas's own cells -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-cell-metrics-test--display-values (text)
  "Return the distinct `display' values TEXT carries."
  (let (values)
    (dotimes (index (length text))
      (let ((value (get-text-property index 'display text)))
        (when (and value (not (member value values)))
          (push value values))))
    (nreverse values)))

(defmacro etaf-ui-cell-metrics-test--with-mount (view &rest body)
  "Mount VIEW on a canvas whose cell differs from the frame's while running BODY.
The canvas cell is 10x18 pixels and the frame's own face 20x40, so a size the
canvas measured and one the frame measured differ.  Images are stubbed, and
the icon cache keys them by their pixel extent, so a later case never receives
the picture this one asked for."
  (declare (indent 1) (debug t))
  `(let ((buffer (generate-new-buffer " *cell-metrics*")))
     (unwind-protect
         (with-current-buffer buffer
           (cl-letf (((symbol-function 'ebox-display-metrics)
                      (lambda (&optional _buffer)
                        (list :char-width 10 :line-height 18 :ascent 100)))
                     ((symbol-function 'frame-char-width)
                      (lambda (&optional _frame) 20))
                     ((symbol-function 'frame-char-height)
                      (lambda (&optional _frame) 40))
                     ((symbol-function 'display-graphic-p)
                      (lambda (&optional _frame) t))
                     ((symbol-function 'image-type-available-p)
                      (lambda (_type) t))
                     ((symbol-function 'create-image)
                      (lambda (&rest _arguments) 'test-cell-metrics-image))
                     ((symbol-function 'image-size)
                      (lambda (&rest _arguments) '(60 . 36))))
             (etaf-mount buffer (etaf-view ,view))
             ,@body))
       (kill-buffer buffer))))

(ert-deftest etaf-ui-cell-metrics-slice-icons-at-the-canvas-row ()
  "A two-row icon is cut at the line height the canvas draws.
`lh' resolves against the canvas's own face, so a slice cut at the frame's
line height leaves the picture a row short of the cells that hold it."
  (etaf-ui-cell-metrics-test--with-mount
      (column (etaf-ui-icon :name 'play :set 'svg :lines 2))
    (let* ((text (buffer-substring (point-min) (point-max)))
           (slices (delq nil (mapcar (lambda (value)
                                       (and (eq 'slice (car-safe (car-safe value)))
                                            (car-safe value)))
                                     (etaf-ui-cell-metrics-test--display-values text)))))
      ;; Ten pixels per row on the canvas, so the second row starts at 18.
      (should (member 18 (mapcar (lambda (slice) (nth 2 slice)) slices)))
      (should (member 18 (mapcar (lambda (slice) (nth 4 slice)) slices))))))

(provide 'etaf-ui-cell-metrics-tests)
