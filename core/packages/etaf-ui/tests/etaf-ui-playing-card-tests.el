;;; -*- lexical-binding: t; -*-
;;; etaf-ui-playing-card-tests.el --- Public card presentation contracts

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'etaf-ui)

(ert-deftest etaf-ui-playing-card-preserves-metrics-and-controlled-activation ()
  "Face, selection and container width keep fixed card geometry and callbacks."
  (let ((buffer (generate-new-buffer " *playing-card-test*"))
        (selected (etaf-ref nil)) (hidden (etaf-ref nil)) (presses 0))
    (unwind-protect
        (let ((runtime
               (etaf-runtime-for-buffer
                (etaf-mount buffer
                  (etaf-view
                   (etaf-playing-card :rank "Q" :suit 'hearts :ref 'card
                     :selected (etaf-value selected) :face-down (etaf-value hidden)
                     :on-press (lambda () (cl-incf presses))))))))
          (etaf-runtime-refit runtime 800 40)
          (let ((size (etaf-host-ref-size runtime 'card)))
            (etaf-dispatch-event runtime 'card 'press)
            (should (= presses 1))
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'card) :aria-label) "Q of hearts"))
            (let* ((bounds (etaf-host-ref-bounds runtime 'card))
                   (face-hover (with-current-buffer buffer
                                 (get-text-property (car bounds) 'mouse-face))))
              (setf (etaf-value hidden) t)
              (let* ((back-bounds (etaf-host-ref-bounds runtime 'card))
                     (back-hover (with-current-buffer buffer
                                   (get-text-property (car back-bounds) 'mouse-face))))
                (should back-hover)
                (should-not (equal face-hover back-hover)))
              (setf (etaf-value hidden) nil))
            (setf (etaf-value selected) t)
            (let ((bounds (etaf-host-ref-bounds runtime 'card)))
              (with-current-buffer buffer
                (should-not (get-text-property (car bounds) 'mouse-face))))
            (should (equal size (etaf-host-ref-size runtime 'card)))
            (etaf-runtime-refit runtime 500 30)
            (should (equal size (etaf-host-ref-size runtime 'card)))
            (setf (etaf-value hidden) t)
            (should (equal (plist-get (etaf-runtime-host-props-for runtime 'card) :aria-label) "Face-down card"))
            (with-current-buffer buffer
              (should-not (string-match-p "Q\\|♥" (buffer-substring-no-properties (point-min) (point-max)))))
            (should (equal size (etaf-host-ref-size runtime 'card)))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ui-playing-card-corners-placeholders-and-validation ()
  "Short corners and empty piles remain readable without leaking hidden cards."
  (let ((buffer (generate-new-buffer " *playing-card-variants*")))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer
                        (etaf-mount buffer
                          (etaf-view
                           (row
                             (etaf-playing-card :rank "10" :suit 'clubs :lines 1 :ref 'corner)
                             (etaf-playing-card :empty t :suit 'spades :ref 'pile)))))))
          (etaf-runtime-refit runtime 500 20)
          (should (= 1 (cdr (etaf-host-ref-size runtime 'corner))))
          (should (= 5 (cdr (etaf-host-ref-size runtime 'pile))))
          (should-error (etaf-dispatch-event runtime 'corner 'press))
          (with-current-buffer buffer
            (should (string-match-p "10 ♣" (buffer-substring-no-properties (point-min) (point-max))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer)))
  (let ((buffer (generate-new-buffer " *playing-card-invalid*")))
    (unwind-protect
        (should-error (etaf-mount buffer (etaf-view (etaf-playing-card :suit 'stars)))
                      :type 'etaf-component-call-error)
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(provide 'etaf-ui-playing-card-tests)
;;; etaf-ui-playing-card-tests.el ends here
