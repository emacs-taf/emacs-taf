;;; etaf-ui-reactions-tests.el --- Reaction chip public behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise `etaf-reactions' through its rendered chips and picker.

;;; Code:
(require 'ert)
(require 'etaf-ui)

(defun etaf-ui-reactions-test--control (runtime label)
  "Find the visible control named LABEL in RUNTIME."
  (car (cl-find-if
        (lambda (entry)
          (and (equal label (plist-get (cdr entry) :aria-label))
               (etaf-host-ref-position runtime (car entry))))
        (etaf-runtime-host-props-entries runtime))))

(defun etaf-ui-reactions-test--press (runtime label)
  "Activate the visible control named LABEL in RUNTIME."
  (let ((ref (etaf-ui-reactions-test--control runtime label)))
    (should ref)
    (etaf-focus runtime ref)
    (etaf-activate runtime)))

(ert-deftest etaf-ui-reactions-toggle-chips-and-pick-choices ()
  "Chips toggle their key, keep their width when chosen, and the picker adds one."
  (with-temp-buffer
    (let* ((items (etaf-ref (list (list :key "👍" :label "👍" :count 2)
                                  (list :key "🔥" :label "🔥" :count 1 :chosen t))))
           toggled
           (toggle (lambda (key)
                     (push key toggled)
                     (setf (etaf-value items)
                           (mapcar (lambda (item)
                                     (if (equal key (plist-get item :key))
                                         (plist-put (copy-sequence item) :chosen
                                                    (not (plist-get item :chosen)))
                                       item))
                                   (etaf-value items))))))
      (unwind-protect
          (progn
            (etaf-mount
             (current-buffer)
             (etaf-view
              (column :width '(ch 60) :height '(lh 12)
                (etaf-reactions :items items :on-toggle toggle
                                :choices '(("❤" . "❤") ("🎉" . "🎉"))))))
            (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                   (row (lambda ()
                          (save-excursion
                            (goto-char (point-min))
                            (search-forward "🔥")
                            (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position)))))
                   (before (funcall row)))
              (should (string-match-p "👍 2" before))
              (should (etaf-ui-reactions-test--control runtime "🔥 1 (chosen)"))
              (etaf-ui-reactions-test--press runtime "👍 2")
              (should (equal toggled '("👍")))
              (should (etaf-ui-reactions-test--control runtime "👍 2 (chosen)"))
              (should (equal (string-width before) (string-width (funcall row))))
              (should-not (string-match-p "🎉" (buffer-substring-no-properties
                                                (point-min) (point-max))))
              (etaf-ui-reactions-test--press runtime "Add reaction")
              (should (string-match-p "🎉" (buffer-substring-no-properties
                                            (point-min) (point-max))))
              (etaf-ui-reactions-test--press runtime "🎉")
              (should (equal toggled '("🎉" "👍")))
              (should-not (string-match-p "🎉" (buffer-substring-no-properties
                                                (point-min) (point-max))))
              (should-error
               (etaf-mount (generate-new-buffer " *reactions-invalid*")
                           (etaf-view (etaf-reactions :items '((:label "x"))
                                                      :on-toggle #'ignore)))
               :type 'etaf-view-error)
              ;; ETAF View keys are scalars, so a compound key is rejected
              ;; when the items are validated instead of failing the render.
              (should-error
               (etaf-mount (generate-new-buffer " *reactions-compound*")
                           (etaf-view
                            (etaf-reactions
                             :items (list (list :key (cons 'custom "61835609")
                                                :label "✦" :count 1))
                             :on-toggle #'ignore)))
               :type 'etaf-view-error)
              (should-error
               (etaf-mount (generate-new-buffer " *reactions-compound-choice*")
                           (etaf-view
                            (etaf-reactions
                             :items '((:key "👍" :label "👍"))
                             :choices (list (cons (cons 'custom "1") "✦"))
                             :on-toggle #'ignore)))
               :type 'etaf-view-error)))
        (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
          (etaf-unmount runtime))))))

(provide 'etaf-ui-reactions-tests)
;;; etaf-ui-reactions-tests.el ends here
