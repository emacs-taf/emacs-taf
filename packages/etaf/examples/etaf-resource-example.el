;;; etaf-resource-example.el --- Resource lifecycle example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example owns a native asynchronous Resource, retains the last successful
;; value during refresh, and lets the Scope cancel work and release results.

;;; Code:

(require 'etaf)

(defconst etaf-resource-example-buffer-name "*ETAF Resource Example*"
  "Buffer opened by `etaf-resource-example-open'.")

(defun etaf-resource-example--message (resource)
  "Return a display message for RESOURCE."
  (pcase (etaf-resource-status resource)
    ('success (etaf-resource-value resource))
    ('error (error-message-string (etaf-resource-error resource)))
    ('loading "Loading service snapshot…")
    ('refreshing (format "Refreshing… %s" (etaf-resource-value resource)))
    ('cancelled "Request cancelled. Reload to try again.")
    (_ "Resource has not loaded.")))

(etaf-define-component etaf-resource-example-app ()
  "Render a reloadable Resource with visible cleanup and error state."
  :bindings
  ((fail-next (etaf-ref nil :name 'etaf-resource-example-fail))
   (cleanup-count (etaf-ref 0 :name 'etaf-resource-example-cleanups))
   (resource
    (let ((generation 0))
      (etaf-resource
       (lambda ()
         (let ((request-generation (cl-incf generation))
               (fail (etaf-value fail-next)))
           (etaf-set-value fail-next nil)
           (etaf-async
            (lambda (resolve reject)
              (let ((timer
                     (run-at-time
                      0.4 nil
                      (lambda ()
                        (if fail
                            (funcall reject
                                     (list 'error (format "Synthetic service failure %d"
                                                          request-generation)))
                          (funcall resolve
                                   (etaf-resource-result
                                    (format "Generation %d is healthy." request-generation)
                                    :cleanup (lambda () (cl-incf (etaf-value cleanup-count))))))))))
                (lambda () (cancel-timer timer)))))))
       :immediate nil :keep-value t :timeout 5 :name 'etaf-resource-example))))
  :setup (etaf-on-mounted (lambda () (etaf-resource-load resource)))
  :view
  (column :width '(px 680) :color "#252A2E" :bgcolor "#F8F5EE"
          (box :width '(px 680) :padding '((lh 1) (px 18)) :border "#8F432F"
               :bgcolor "#FFFDF8" :text-align 'center
               (column
                (text :color "#8F432F" :font-weight 'bold
                      "BEST PRACTICE  /  RESOURCE LIFECYCLE")
                (text :font-weight 'bold "Service health")
                (text :color "#66706A"
                      "Async refresh keeps the last value; cancellation stays scoped.")))
          (box :height '(lh 1))
          (box :width '(px 680) :padding '((lh 2) (px 18))
               :border
               (if (eq (etaf-resource-status
                        resource) 'success)
                   "#6D8A73" "#C97252")
               :bgcolor
               (if (eq (etaf-resource-status
                        resource) 'success)
                   "#DCEBDD" "#F1D4C9")
               :color
               (if (eq (etaf-resource-status
                        resource) 'success)
                   "#24422D" "#6B3020")
               :text-align 'center
               (column
                (text :font-weight 'bold
                      (expr
                       (upcase
                        (symbol-name
                         (etaf-resource-status resource)))))
                (text
                 (expr
                  (etaf-resource-example--message
                   resource)))
                (text :color "#66706A"
                      (expr
                       (format "CLEANUPS  %d"
                               (etaf-value cleanup-count))))))
          (box :height '(lh 1))
          (flex :width '(px 680) :flex-flow '(row wrap) :gap '((lh 1) (px 12))
                (box :flex-grow 1 :flex-shrink 1 :flex-basis '(px 200)
                     :min-width '(px 180) :padding '((lh 1) (px 12))
                     :border "#4E7890" :bgcolor "#D9EAF2" :font-weight 'bold
                     :text-align 'center :ref 'resource-reload :role 'button
                     :use (list (etaf-focusable))
                     :on-press
                     (lambda () (etaf-resource-load resource))
                     (text "RELOAD"))
                (box :flex-grow 1 :flex-shrink 1 :flex-basis '(px 200)
                     :min-width '(px 180) :padding '((lh 1) (px 12))
                     :border "#C97252" :bgcolor "#F1D4C9" :font-weight 'bold
                     :text-align 'center :ref 'resource-fail :role 'button
                     :use (list (etaf-focusable))
                     :on-press
                     (lambda ()
                       (etaf-set-value fail-next t)
                       (etaf-resource-load resource))
                     (text "SIMULATE FAILURE"))
                (box :flex-grow 1 :flex-shrink 1 :flex-basis '(px 200)
                     :min-width '(px 180) :padding '((lh 1) (px 12))
                     :border "#8D887F" :bgcolor "#EEEAE2" :font-weight 'bold
                     :text-align 'center :ref 'resource-cancel :role 'button
                     :tab-index 0
                     :disabled (not (memq (etaf-resource-status resource) '(loading refreshing)))
                     :on-press (lambda () (etaf-resource-cancel resource))
                     (text "CANCEL")))
          (box :height '(lh 1))
          (box :width '(px 680) :padding '((lh 1) (px 16)) :border "#8D887F"
               :color "#4D5651" :bgcolor "#EEEAE2"
               (text
                "Scope rule: replace releases the old value; unmount cancels and releases"))))

;;;###autoload
(defun etaf-resource-example-view ()
  "Return the Resource lifecycle example View."
  (etaf-view (etaf-resource-example-app)))

;;;###autoload
(defun etaf-resource-example-open ()
  "Mount the Resource lifecycle example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-resource-example-buffer-name
                            (etaf-resource-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-resource-example-close ()
  "Unmount and kill the Resource lifecycle example buffer."
  (interactive)
  (when-let* ((runtime
              (etaf-runtime-for-buffer etaf-resource-example-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-resource-example-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-resource-example)

;;; etaf-resource-example.el ends here
