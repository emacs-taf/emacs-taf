;;; etaf-retained-resize.el --- Mounted fixed-text resize example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A real ETAF Runtime and controlled Behavior resize a clipped panel whose
;; geometry relayouts only the panel.  This deliberately has no window chrome
;; or paragraph reflow.
;; Drag the panel, Shift-drag to lock, and Escape to restore the starting size.
;; The peer remains an independently owned, keyboard-accessible input target.

;;; Code:
(require 'etaf)

;;;###autoload
(defun etaf-retained-resize-open (&optional buffer-or-name)
  "Mount a native fixed-text resize example in BUFFER-OR-NAME.
Default to *ETAF Retained Resize*.  Return the buffer; interactive calls
show it.  Drag anywhere in the panel to resize its bottom/right edges.
Shift locks the gesture until the next click; Escape restores its start.
The body clips fixed text, not paragraph reflow or a catalog window frame.
Use `etaf-unmount' or kill the buffer to release the mounted example."
  (interactive)
  (let* ((buffer (get-buffer-create (or buffer-or-name "*ETAF Retained Resize*")))
         (previous (etaf-runtime-for-buffer buffer))
         (width (etaf-ref '(px 320) :test #'equal))
         (height (etaf-ref '(lh 8) :test #'equal))
         origin behavior)
    (when (and (not previous) (> (buffer-size buffer) 0))
      (user-error "Refusing to replace unrelated contents in %s" (buffer-name buffer)))
    (when previous (etaf-unmount previous))
    (setq behavior
          (etaf-resizable-controlled
           (lambda () (list :x 16 :y 2 :width (cadr (etaf-value width))
                            :height (cadr (etaf-value height))))
           (lambda (next)
             (etaf-batch
               (etaf-set-value width (list 'px (plist-get next :width)))
               (etaf-set-value height (list 'lh (plist-get next :height)))))
           :edges '(right bottom) :min-width 80 :max-width 600 :min-height 2 :max-height 20
           :delta (lambda (gesture)
                    (let ((delta (plist-get gesture :delta))
                          (window (plist-get gesture :window)))
                      (cons (round (car delta))
                            (round (/ (float (cdr delta))
                                      (if (window-live-p window)
                                          (max 1 (frame-char-height (window-frame window)))
                                        1))))))
           :on-start (lambda (_gesture) (setq origin (list (etaf-value width) (etaf-value height))))
           :on-end (lambda (_gesture) (setq origin nil))
           :on-cancel
           (lambda (gesture)
             (when (and origin (eq (plist-get gesture :reason) 'quit))
               (etaf-batch (etaf-set-value width (car origin))
                          (etaf-set-value height (cadr origin))))
             (setq origin nil))))
    (etaf-mount
     buffer
     (etaf-view
      (box :position 'relative :width '(px 640) :height '(lh 24)
           :background-color "#EAF0F6" :color "#243447"
        (text "Drag the dark panel to resize. Shift locks; Escape cancels.")
        (box :id "resize-panel" :ref 'resize-panel :position 'absolute
             :left '(px 16) :top '(lh 2)
             :width (etaf-value width) :height (etaf-value height) :z-index 2
             :min-width '(px 0) :min-height '(lh 0) :overflow 'hidden :wrap-mode 'none
             :background-color "#243447" :color "#F1F5F9"
             :role 'region :aria-label "Resize fixed panel" :tab-index 0
             :pointer 'nhdrag :drag-lock-modifier 'shift :use behavior
          (text "Fixed native text, published by Ebox\nABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\n中文内容：缩小裁剪，放大恢复。\nNo image preview or alternate buffer writer."))
        (box :id "resize-peer" :ref 'resize-peer :position 'absolute
             :left '(px 350) :top '(lh 10) :width '(px 180) :height '(lh 3) :z-index 1
             :background-color "#705070" :color "#FFFFFF"
             :role 'button :aria-label "Independent peer" :tab-index 0
             :on-press (lambda () (message "Independent peer activated"))
          (text "Independent peer\nClick or press Return")))))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    buffer))

(provide 'etaf-retained-resize)
;;; etaf-retained-resize.el ends here
