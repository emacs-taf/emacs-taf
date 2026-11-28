;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-views.el --- Canvas-only presentation

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; There is no workspace chrome, control panel or interactive scene surface.
;; Every input belongs to the presentation owner and dismisses the screensaver.

;;; Code:
(require 'etaf)
(require 'etaf-screensaver-engine)

(etaf-define-component etaf-screensaver-view (&key session on-close)
  "Draw SESSION's retained canvas; call ON-CLOSE when unmounted."
  :bindings ((size (etaf-screensaver--session-size session))
             (revision (etaf-screensaver--session-revision session)))
  :setup (etaf-on-unmounted on-close)
  :view
  (box :width (list 'ch (car (etaf-value size)))
       :height (list 'lh (cdr (etaf-value size)))
       :position 'static :left '(px 0) :top '(lh 0) :z-index 0
       :wrap-mode 'none :overflow 'hidden
       :background-color
       (progn (etaf-value revision)
              (etaf-screensaver--session-background session))
    (box :for (row (progn (etaf-value size) (etaf-value revision)
                          (etaf-screensaver--session-publication session)))
         :key (car row) :height '(lh 1)
      (text :ref (car row) (expr (cdr row))))))

(provide 'etaf-screensaver-views)
;;; etaf-screensaver-views.el ends here
