;;; etaf-error-boundary-tests.el --- Tests for declarative etaf-error-boundary -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Acceptance tests for the declarative `etaf-error-boundary' Component covering
;; synchronous render errors, reactive update errors, event callback errors,
;; reset recovery, sibling isolation, fallback bubbling, and `quit' propagation.

;;; Code:

(require 'ert)
(require 'etaf)

(defun etaf-eb-tests--text (buffer)
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(etaf-define-component etaf-eb-tests--exploder (&key explode-ref on-press-explode)
  "Test child component that can explode during render, update, or press."
  :bindings ((mounts (etaf-ref 0)))
  :render
  (progn
    (when (and explode-ref (etaf-value explode-ref))
      (error "Child exploded: %S" (etaf-value explode-ref)))
    (etaf-view
     (box :ref 'eb-child-box
          :on-press (lambda ()
                      (when on-press-explode
                        (error "Event exploded")))
       (text (expr (format "healthy-child-%d" (etaf-value mounts))))))))

(ert-deftest etaf-error-boundary-catches-sync-render-error ()
  "Synchronous render error inside boundary renders fallback while sibling survives."
  (let* ((buf (generate-new-buffer " *etaf-eb-sync*"))
         (boom (etaf-ref 'sync-boom))
         (caught nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (column
              (text :ref 'eb-sibling "sibling-ok")
              (etaf-error-boundary
               :name 'widget-a
               :on-error (lambda (info) (setq caught info))
               :fallback (lambda (info _reset)
                           (etaf-view
                            (text :ref 'eb-fb
                                  (expr (format "FALLBACK:%s:%s"
                                                (plist-get info :phase)
                                                (plist-get info :name))))))
               (etaf-eb-tests--exploder :explode-ref boom)))))
          (let ((txt (etaf-eb-tests--text buf)))
            (should (string-match-p "sibling-ok" txt))
            (should (string-match-p "FALLBACK:render:widget-a" txt))
            (should-not (string-match-p "healthy-child" txt)))
          (should (eq (plist-get caught :phase) 'render))
          (should (eq (plist-get caught :name) 'widget-a))
          (should (string-match-p "sync-boom"
                                  (error-message-string (plist-get caught :error)))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-error-boundary-catches-reactive-update-error ()
  "Reactive update error isolates to fallback while healthy sibling still updates."
  (let* ((buf (generate-new-buffer " *etaf-eb-update*"))
         (boom (etaf-ref nil))
         (sibling-count (etaf-ref 0))
         (caught nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (column
              (text :ref 'eb-sib (expr (format "sib=%d" (etaf-value sibling-count))))
              (etaf-error-boundary
               :name 'widget-b
               :on-error (lambda (info) (setq caught info))
               :fallback (lambda (info _reset)
                           (etaf-view
                            (text (expr (format "CAUGHT:%s:%s"
                                                (plist-get info :phase)
                                                (error-message-string
                                                 (plist-get info :error)))))))
               (etaf-eb-tests--exploder :explode-ref boom)))))
          (should (string-match-p "healthy-child" (etaf-eb-tests--text buf)))
          (should (string-match-p "sib=0" (etaf-eb-tests--text buf)))
          ;; Trigger both sibling update and child crash in the same batch.
          (etaf-batch
           (etaf-set-value sibling-count 1)
           (etaf-set-value boom 'update-boom))
          (let ((txt (etaf-eb-tests--text buf)))
            (should (string-match-p "sib=1" txt))
            (should (string-match-p "CAUGHT:update:.*update-boom" txt))
            (should-not (string-match-p "healthy-child" txt)))
          (should (eq (plist-get caught :phase) 'update))
          ;; Healthy sibling continues updating after boundary tripped.
          (etaf-set-value sibling-count 2)
          (should (string-match-p "sib=2" (etaf-eb-tests--text buf))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-error-boundary-catches-event-callback-error ()
  "Event callback error inside boundary trips to fallback without crashing dispatch."
  (let* ((buf (generate-new-buffer " *etaf-eb-event*"))
         (boom (etaf-ref nil))
         (caught nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (column
              (text "outer-ok")
              (etaf-error-boundary
               :name 'widget-ev
               :on-error (lambda (info) (setq caught info))
               :fallback (lambda (info _reset)
                           (etaf-view
                            (text (expr (format "EVENT-FB:%s"
                                                (plist-get info :phase))))))
               (etaf-eb-tests--exploder :explode-ref boom :on-press-explode t)))))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (should (string-match-p "healthy-child" (etaf-eb-tests--text buf)))
            (should (null (etaf-dispatch-event rt 'eb-child-box 'press)))
            (let ((txt (etaf-eb-tests--text buf)))
              (should (string-match-p "outer-ok" txt))
              (should (string-match-p "EVENT-FB:event" txt))
              (should-not (string-match-p "healthy-child" txt)))
            (should (eq (plist-get caught :phase) 'event))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-error-boundary-reset-remounts-fresh-and-recovers ()
  "Calling fallback RESET clears the error, remounts children fresh, and recovers."
  (let* ((buf (generate-new-buffer " *etaf-eb-reset*"))
         (boom (etaf-ref 'first-crash))
         (reset-fn nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (etaf-error-boundary
             :name 'recoverable
             :fallback (lambda (info reset)
                         (setq reset-fn reset)
                         (etaf-view
                          (box :ref 'eb-retry-btn :on-press reset
                            (text (expr (format "RETRY:%s"
                                                (plist-get info :phase)))))))
             (etaf-eb-tests--exploder :explode-ref boom))))
          (should (string-match-p "RETRY:render" (etaf-eb-tests--text buf)))
          (should (functionp reset-fn))
          ;; Retry while error condition still active: stays in fallback cleanly.
          (etaf-dispatch-event (etaf-runtime-for-buffer buf) 'eb-retry-btn 'press)
          (should (string-match-p "RETRY:render" (etaf-eb-tests--text buf)))
          ;; Clear underlying error and trigger retry: recovers cleanly!
          (etaf-set-value boom nil)
          (etaf-dispatch-event (etaf-runtime-for-buffer buf) 'eb-retry-btn 'press)
          (let ((txt (etaf-eb-tests--text buf)))
            (should (string-match-p "healthy-child-0" txt))
            (should-not (string-match-p "RETRY:" txt))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-error-boundary-propagates-quit-and-fallback-errors ()
  "User `quit' is never swallowed, and errors inside fallback bubble to outer boundary."
  (let* ((buf (generate-new-buffer " *etaf-eb-bubble*"))
         (boom (etaf-ref 'inner-crash)))
    (unwind-protect
        (progn
          ;; Nested boundary: inner fallback throws, outer boundary catches it.
          (etaf-mount
           buf
           (etaf-view
            (etaf-error-boundary
             :name 'outer
             :fallback (lambda (info _reset)
                         (etaf-view
                          (text (expr (format "OUTER-CAUGHT:%s"
                                              (error-message-string
                                               (plist-get info :error)))))))
             (etaf-error-boundary
              :name 'inner
              :fallback (lambda (_info _reset)
                          (error "broken-fallback"))
              (etaf-eb-tests--exploder :explode-ref boom)))))
          (should (string-match-p "OUTER-CAUGHT:broken-fallback"
                                  (etaf-eb-tests--text buf))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf))))
  ;; `quit' must NEVER be swallowed by `etaf-error-boundary'.
  (let ((buf (generate-new-buffer " *etaf-eb-quit*")))
    (unwind-protect
        (should
         (eq 'caught-quit
             (condition-case nil
                 (progn
                   (etaf-mount
                    buf
                    (etaf-view
                     (etaf-error-boundary
                      :name 'no-quit
                      :fallback "SHOULD-NOT-SHOW"
                      (box :ref 'eb-quit-box
                        (text (expr (signal 'quit nil)))))))
                   'did-not-quit)
               (quit 'caught-quit))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'etaf-error-boundary-tests)
;;; etaf-error-boundary-tests.el ends here
