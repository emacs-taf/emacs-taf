;;; etaf-devtools-tests.el --- Public API acceptance tests for etaf-devtools -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public-API acceptance scenarios covering `etaf-devtools-open',
;; `etaf-devtools-close', `etaf-devtools-highlight-updates',
;; `etaf-devtools-toggle-dock', `etaf-devtools-create', `etaf-devtools-view',
;; `etaf-devtools-dispose' and `etaf-devtools-doctor'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-devtools)

(etaf-define-component etaf-dt-test-widget (&key (label "Item"))
  :bindings ((count (etaf-ref 3 :name 'count))
             (flag (etaf-ref nil :name 'flag))
             (summary (etaf-computed
                       (lambda () (format "%s=%d(%s)" label (etaf-value count) (etaf-value flag)))
                       :name 'summary)))
  :styles (("&.demo-card" :padding ((lh 1) (ch 2)) :color "#ffffff" :background-color "#2e3a40"))
  :view (box :id "demo-box" :class "demo-card" :ref 'demo-card
             :border-top-width '(px 1) :border-top-style 'solid :border-top-color "#444e53"
             :border-bottom-width '(px 1) :border-bottom-style 'solid :border-bottom-color "#444e53"
             :border-left-width '(px 1) :border-left-style 'solid :border-left-color "#444e53"
             :border-right-width '(px 1) :border-right-style 'solid :border-right-color "#444e53"
             :tab-index 0
             :aria-label "Demo Card"
             :on-press (lambda () (etaf-update-value count #'1+))
             (text :ref 'demo-text (expr (etaf-value summary)))))

(defun etaf-dt-test--mount-target (name)
  "Mount a sample ETAF target application in buffer NAME and return its Runtime."
  (let* ((buf (generate-new-buffer name))
         (view (etaf-view
                (column :width '(ch 50)
                        :region '(:id workspace :label "Workspace" :key ?w :enter demo-card)
                        :keys `(("z" ,(lambda () nil) "Sample Key"))
                        (etaf-dt-test-widget :label "Alpha")))))
    (etaf-mount buf view '(:viewport-width 420 :viewport-height 24))
    (etaf-runtime-for-buffer buf)))

(defun etaf-dt-test--plain (buffer)
  "Return plain text of BUFFER without text properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-dt-test--count-dt-overlays (buffer)
  "Return number of `etaf-devtools-overlay' overlays currently in BUFFER."
  (with-current-buffer buffer
    (cl-count-if (lambda (ov) (overlay-get ov 'etaf-devtools-overlay))
                 (overlays-in (point-min) (point-max)))))

(ert-deftest etaf-devtools-open-renders-target-and-excludes-self ()
  "Opening DevTools attaches to the target, shows tree/styles and skips itself."
  (let ((etaf-devtools-use-posframe nil)
        (target-rt (etaf-dt-test--mount-target " *dt-target-1*")))
    (unwind-protect
        (progn
          (etaf-devtools-open target-rt)
          (let* ((dt-buf (get-buffer "*etaf-devtools*"))
                 (dt-rt (and dt-buf (etaf-runtime-for-buffer dt-buf))))
            (should (buffer-live-p dt-buf))
            (should (and dt-rt (etaf-runtime-mounted-p dt-rt)))
            ;; Simulate a standard 68-col desktop side window (medium tier)
            (etaf-runtime-refit dt-rt 640 32)
            (let ((text (etaf-dt-test--plain dt-buf)))
              (should (string-match-p "dt-target-1" text))
              (should (string-match-p "etaf-dt-test-widget" text))
              (should (string-match-p "ECSS" text))
              ;; Switch to Runtime tab via key 6 and ensure *etaf-devtools* never lists itself
              (with-current-buffer dt-buf
                (execute-kbd-macro "6"))
              (let ((rt-text (etaf-dt-test--plain dt-buf)))
                (should (string-match-p "dt-target-1" rt-text))
                (should-not (string-match-p "\\*etaf-devtools\\*.*rev:" rt-text))))))
      (etaf-devtools-close)
      (when (buffer-live-p (etaf-runtime-buffer target-rt))
        (ignore-errors (etaf-unmount target-rt))
        (kill-buffer (etaf-runtime-buffer target-rt))))))

(ert-deftest etaf-devtools-tabs-and-responsive-viewports-render-cleanly ()
  "All 6 tabs render cleanly across wide, medium and narrow viewports."
  (let ((etaf-devtools-use-posframe nil)
        (target-rt (etaf-dt-test--mount-target " *dt-target-2*")))
    (unwind-protect
        (progn
          (etaf-devtools-open target-rt)
          (let* ((dt-buf (get-buffer "*etaf-devtools*"))
                 (dt-rt (etaf-runtime-for-buffer dt-buf)))
            ;; Test wide, medium, narrow refits
            (dolist (vp '((1100 . 34) (640 . 30) (400 . 20)))
              (etaf-runtime-refit dt-rt (car vp) (cdr vp))
              (with-current-buffer dt-buf
                (dolist (key '("1" "2" "3" "4" "5" "6"))
                  (execute-kbd-macro key))))
            ;; Check State tab shows named bindings
            (etaf-runtime-refit dt-rt 960 32)
            (with-current-buffer dt-buf
              (execute-kbd-macro "3"))
            (let ((state-txt (etaf-dt-test--plain dt-buf)))
              (should (string-match-p "etaf-dt-test-widget" state-txt))
              (should (string-match-p "count" state-txt))
              (should (string-match-p "summary" state-txt)))
            ;; Check Keys tab shows focus stops and region
            (with-current-buffer dt-buf
              (execute-kbd-macro "5"))
            (let ((keys-txt (etaf-dt-test--plain dt-buf)))
              (should (string-match-p "Tab Focus Stops" keys-txt))
              (should (string-match-p "workspace" keys-txt)))))
      (etaf-devtools-close)
      (when (buffer-live-p (etaf-runtime-buffer target-rt))
        (ignore-errors (etaf-unmount target-rt))
        (kill-buffer (etaf-runtime-buffer target-rt))))))

(ert-deftest etaf-devtools-highlight-updates-is-zero-distortion-and-cleans-up ()
  "Highlight Updates flashes via read-only overlays without touching revision or text."
  (let* ((etaf-devtools-use-posframe nil)
         (target-rt (etaf-dt-test--mount-target " *dt-target-3*"))
         (target-buf (etaf-runtime-buffer target-rt)))
    (unwind-protect
        (progn
          (should (etaf-devtools-highlight-updates 1 target-rt))
          (let ((rev-before (etaf-runtime-revision target-rt))
                (text-before (etaf-dt-test--plain target-buf)))
            ;; Trigger one real press on target card
            (etaf-dispatch-event target-rt 'demo-card 'press)
            (let ((rev-after (etaf-runtime-revision target-rt))
                  (text-after (etaf-dt-test--plain target-buf))
                  (ov-count (etaf-dt-test--count-dt-overlays target-buf)))
              ;; Exactly one revision bump from the real app press, zero extra from overlays
              (should (= rev-after (1+ rev-before)))
              (should (string-match-p "Alpha=4" text-after))
              (should-not (equal text-before text-after))
              (should (> ov-count 0))))
          ;; Disabling clears every overlay immediately
          (should-not (etaf-devtools-highlight-updates 0 target-rt))
          (should (= 0 (etaf-dt-test--count-dt-overlays target-buf))))
      (etaf-devtools-close)
      (when (buffer-live-p target-buf)
        (ignore-errors (etaf-unmount target-rt))
        (kill-buffer target-buf)))))

(ert-deftest etaf-devtools-live-ref-edit-and-viewport-qa-drive-target ()
  "Controlled ref mutation updates target output and QA viewport refit works."
  (let* ((etaf-devtools-use-posframe nil)
         (target-rt (etaf-dt-test--mount-target " *dt-target-4*"))
         (target-buf (etaf-runtime-buffer target-rt)))
    (unwind-protect
        (progn
          (etaf-devtools-open target-rt)
          (let* ((dt-buf (get-buffer "*etaf-devtools*"))
                 (tree (etaf-runtime-inspect-tree target-rt))
                 (comp (cl-labels ((find-c (ns)
                                     (cl-loop for n in ns
                                              for hit = (if (and (eq (plist-get n :kind) 'component)
                                                                 (eq (plist-get n :name) 'etaf-dt-test-widget))
                                                            n
                                                          (find-c (plist-get n :children)))
                                              when hit return hit)))
                         (find-c tree))))
            (should comp)
            ;; Live edit writable ref count -> 99
            (should (etaf-runtime-set-component-binding target-rt (plist-get comp :id) 'count 99))
            (should (string-match-p "Alpha=99" (etaf-dt-test--plain target-buf)))
            ;; Cycle QA viewport preset via W key in DevTools
            (with-current-buffer dt-buf
              (execute-kbd-macro "W"))
            (let ((vp (etaf-runtime-viewport target-rt)))
              (should (= (car vp) 1280))
              (should (= (cdr vp) 42)))))
      (etaf-devtools-close)
      (when (buffer-live-p target-buf)
        (ignore-errors (etaf-unmount target-rt))
        (kill-buffer target-buf)))))

(ert-deftest etaf-devtools-headless-session-survives-target-unmount-and-doctor ()
  "Headless create/view/dispose handles target unmount cleanly and doctor passes."
  (let* ((etaf-devtools-use-posframe nil)
         (target-rt (etaf-dt-test--mount-target " *dt-target-5*"))
         (target-buf (etaf-runtime-buffer target-rt))
         (host-buf (generate-new-buffer " *dt-headless*"))
         (session (etaf-devtools-create target-rt)))
    (unwind-protect
        (progn
          (etaf-mount host-buf (etaf-devtools-view session)
                      '(:viewport-width 680 :viewport-height 26))
          (should (string-match-p "dt-target-5" (etaf-dt-test--plain host-buf)))
          ;; Unmounting target does not error and cleans up safely
          (etaf-unmount target-rt)
          (kill-buffer target-buf)
          (sleep-for 0.08)
          (let ((doc (etaf-devtools-doctor)))
            (should (plist-get doc :required))
            (should (cl-every (lambda (c) (plist-get c :ok))
                              (plist-get doc :required)))))
      (etaf-devtools-dispose session)
      (when (buffer-live-p host-buf)
        (ignore-errors (etaf-unmount (etaf-runtime-for-buffer host-buf)))
        (kill-buffer host-buf))
      (when (buffer-live-p target-buf)
        (ignore-errors (etaf-unmount target-rt))
        (kill-buffer target-buf)))))

(provide 'etaf-devtools-tests)
;;; etaf-devtools-tests.el ends here
