;;; etaf-counter-example.el --- Retained state example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example keeps state inside one retained Component, derives display
;; values with `etaf-computed', and routes named mutations through an Action.

;;; Code:

(require 'etaf)

(defconst etaf-counter-example-buffer-name "*ETAF Counter Example*"
  "Buffer opened by `etaf-counter-example-open'.")

(etaf-action-define etaf-counter-example-update (runtime count operation)
  "Apply OPERATION to COUNT inside RUNTIME."
  (ignore runtime)
  (etaf-update-value
   count
   (lambda (value)
     (pcase operation
       ('increment (1+ value))
       ('decrement (max 0 (1- value)))
       ('reset 0)
       (_ (user-error "Unknown counter operation: %S" operation))))))

(etaf-define-component etaf-counter-example-action
    (&key count label operation)
  "Render one semantic counter action."
  :view
  (box :class "action" :role 'button :use (list (etaf-focusable))
       :on-press
       (lambda () (etaf-dispatch 'etaf-counter-example-update count operation))
    (text (expr label)))
  :styles
  (("&" :flex-grow 1 :flex-shrink 1 :flex-basis (px 160)
    :min-width (px 140) :padding ((lh 1) (px 12)) :border "#4E7890"
    :bgcolor "#D9EAF2" :text-align center :font-weight bold)))

(etaf-define-component etaf-counter-example-card (&key title initial-value)
  "Render a retained counter named TITLE starting at INITIAL-VALUE."
  :bindings
  ((count (etaf-ref (or initial-value 0) :name 'counter))
   (double (etaf-computed
            (lambda () (* 2 (etaf-value count)))
            :name 'counter-double))
   (status (etaf-computed
            (lambda ()
              (if (zerop (etaf-value count)) "READY" "ACTIVE"))
            :name 'counter-status)))
  :view
  (column
   (box :class "hero"
        (column
         (text :class "eyebrow" "BEST PRACTICE  /  RETAINED STATE")
         (text :font-weight 'bold (expr title))
         (text :color "#66706A"
               "Bindings initialize once; rendering reads their values.")))
   (box :height '(lh 1))
   (flex :width '(px 680) :flex-flow '(row wrap) :gap '((lh 1) (px 12))
         (box :class "metric"
              (text (expr
                     (format "COUNT  %d"
                             (etaf-value count)))))
         (box :class "metric"
              (text (expr
                     (format "DOUBLE  %d"
                             (etaf-value double)))))
         (box :class "metric"
              (text (expr
                     (format "STATE  %s"
                             (etaf-value status))))))
   (box :height '(lh 1))
   (flex :width '(px 680) :flex-flow '(row wrap) :gap '((lh 1) (px 12))
         (etaf-counter-example-action
          :ref 'counter-decrement
          :count count
          :label "−  DECREMENT" :operation 'decrement)
         (etaf-counter-example-action
          :ref 'counter-reset
          :count count
          :label "RESET" :operation 'reset)
         (etaf-counter-example-action
          :ref 'counter-increment
          :count count
          :label "+  INCREMENT" :operation 'increment))
   (box :height '(lh 1))
   (box :class "note"
        (text "Public path: Event → Action → Ref → Computed → Runtime commit")))
  :styles
  (("&" :width (px 680) :color "#252A2E" :bgcolor "#F8F5EE")
   (".hero" :width (px 680) :padding ((lh 1) (px 18)) :border "#8F432F"
    :bgcolor "#FFFDF8" :text-align center)
   (".eyebrow" :color "#8F432F" :font-weight bold)
   (".metric" :flex-grow 1 :flex-shrink 1 :flex-basis (px 200)
    :min-width (px 180) :padding ((lh 1) (px 14)) :border "#6D8A73"
    :bgcolor "#DCEBDD" :text-align center)
   (".note" :width (px 680) :padding ((lh 1) (px 16)) :border "#8D887F"
    :color "#4D5651" :bgcolor "#EEEAE2")))

;;;###autoload
(defun etaf-counter-example-view ()
  "Return the counter example View."
  (etaf-view
   (etaf-counter-example-card
    :title "Counter workspace"
    :initial-value 2)))

;;;###autoload
(defun etaf-counter-example-open ()
  "Mount the counter example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-counter-example-buffer-name
                            (etaf-counter-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-counter-example-close ()
  "Unmount and kill the counter example buffer."
  (interactive)
  (when-let* ((runtime
              (etaf-runtime-for-buffer etaf-counter-example-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-counter-example-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-counter-example)

;;; etaf-counter-example.el ends here
