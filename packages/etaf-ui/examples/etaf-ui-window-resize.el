;;; etaf-ui-window-resize.el --- Native catalog window resize example -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; The ordinary catalog shell uses caller-owned refs and controlled Behaviors.
;; Ebox owns rendering, native event tracking, hit regions and publication.
;;; Code:
(require 'etaf-ui)

;;;###autoload
(defun etaf-ui-window-resize-open (&optional buffer-or-name)
  "Open a controlled catalog window in BUFFER-OR-NAME and return its buffer.
The default is *ETAF Window Resize*. Drag the title to move; all eight handles
resize. Shift locks a gesture, another click confirms, and Escape restores
its starting rectangle. The fixed body clips rather than reflowing paragraphs.
Interactive calls display the example; use `etaf-unmount' or kill its buffer
to dispose it. This example alone does not certify a latency budget."
  (interactive)
  (let* ((buffer (get-buffer-create (or buffer-or-name "*ETAF Window Resize*")))
         (previous (etaf-runtime-for-buffer buffer))
         (x (etaf-ref '(px 16) :test #'equal)) (y (etaf-ref '(lh 2) :test #'equal))
         (width (etaf-ref '(px 360) :test #'equal)) (height (etaf-ref '(lh 12) :test #'equal))
         (read (lambda () (list :x (cadr (etaf-value x)) :y (cadr (etaf-value y))
                               :width (cadr (etaf-value width)) :height (cadr (etaf-value height)))))
         (write (lambda (next)
                  (etaf-batch
                    (etaf-set-value x (list 'px (max 0 (plist-get next :x))))
                    (etaf-set-value y (list 'lh (max 0 (plist-get next :y))))
                    (when (plist-member next :width)
                      (etaf-set-value width (list 'px (plist-get next :width))))
                    (when (plist-member next :height)
                      (etaf-set-value height (list 'lh (plist-get next :height)))))))
         (delta (lambda (gesture)
                  (let ((pixels (plist-get gesture :delta)) (window (plist-get gesture :window)))
                    (cons (round (car pixels))
                          (round (/ (float (cdr pixels))
                                    (if (window-live-p window)
                                        (max 1 (frame-char-height (window-frame window))) 1)))))))
         origin handles move)
    (when (and (not previous) (> (buffer-size buffer) 0))
      (user-error "Refusing to replace unrelated buffer contents"))
    (when previous (etaf-unmount previous))
    (let ((start (lambda (_gesture) (setq origin (funcall read))))
          (end (lambda (_gesture) (setq origin nil)))
          (cancel (lambda (gesture)
                    (when (and origin (eq (plist-get gesture :reason) 'quit))
                      (funcall write origin))
                    (setq origin nil))))
      (setq move (etaf-draggable-controlled
                  (lambda () (list :x (cadr (etaf-value x)) :y (cadr (etaf-value y))))
                  write :axis 'both :delta delta :on-start start :on-end end :on-cancel cancel))
      (dolist (edge '(left right top bottom top-left top-right bottom-left bottom-right))
        (push (cons edge (etaf-resizable-controlled
                         read write :edges (pcase edge
                                             ('top-left '(left top)) ('top-right '(right top))
                                             ('bottom-left '(left bottom)) ('bottom-right '(right bottom))
                                             (_ (list edge)))
                         :min-width 240 :max-width 680 :min-height 6 :max-height 26
                         :delta delta :on-start start :on-end end :on-cancel cancel)) handles)))
    (etaf-mount
     buffer
     (etaf-view
      (box :position 'relative :width '(px 720) :height '(lh 30)
           :background-color "#EAF0F6"
        (etaf-window :id "resize-window" :ref 'resize-window :chrome-ref 'resize-title
                     :title "Native window resize" :x x :y y :width width :height height
                     :z-index 2 :move-use move :resize-use handles
                     :resize-refs '((left . resize-left) (right . resize-right)
                                    (top . resize-top) (bottom . resize-bottom)
                                    (top-left . resize-top-left) (top-right . resize-top-right)
                                    (bottom-left . resize-bottom-left) (bottom-right . resize-bottom-right))
                     :on-close (lambda () (when (buffer-live-p buffer) (kill-buffer buffer)))
          (box :width '(px 640) :height '(lh 20) :wrap-mode 'none :overflow 'hidden
            (text "Real etaf-window: native text, title, border and eight handles.\n拖动边缘或角落缩放，Shift 锁定，Escape 恢复。\nFixed content clips and is restored when expanded.\nThe independent panel remains below this window.")))
        (box :ref 'resize-peer :position 'absolute :left '(px 380) :top '(lh 10)
             :width '(px 240) :height '(lh 7) :z-index 1 :background-color "#705070"
             :color "#FFFFFF" :tab-index 0 :role 'button
             :on-press (lambda () (message "Independent target activated"))
          (text "Independent native target\nClick or press Return")))))
    (when (called-interactively-p 'interactive) (pop-to-buffer buffer))
    buffer))

(provide 'etaf-ui-window-resize)
;;; etaf-ui-window-resize.el ends here
