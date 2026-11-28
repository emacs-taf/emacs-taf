;;; etaf-ui-virtual-list-tests.el --- Tests for etaf-virtual-list -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Acceptance tests and 5,000-row performance verification for `etaf-virtual-list':
;; O(viewport) rendered Host budget, fixed-height fast path, dynamic height
;; measurement with `:scroll-anchor', keyboard navigation, empty state, and
;; 500 vs 5,000 constant-order mount/scroll benchmark.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)

(defun etaf-vl-tests--text (buffer)
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-vl-tests--items (count)
  "Build a vector of COUNT synthetic row plists."
  (let ((vec (make-vector count nil)))
    (dotimes (i count vec)
      (aset vec i (list :key i :title (format "Row #%04d" i))))))

(ert-deftest etaf-ui-virtual-list-fixed-height-renders-o-viewport-and-scrolls ()
  "Fixed-height 5,000-row virtual list renders only O(viewport) rows and scrolls smoothly."
  (let* ((buf (generate-new-buffer " *etaf-vl-fixed*"))
         (items (etaf-vl-tests--items 5000))
         (rendered-count 0)
         (scroll-events nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (etaf-virtual-list
             :ref 'vl-fixed
             :items items
             :item-key (lambda (it) (plist-get it :key))
             :item-height 1
             :height 20
             :overscan 4
             :on-scroll (lambda (off) (push off scroll-events))
             :render-item (lambda (it _idx _sel)
                            (cl-incf rendered-count)
                            (etaf-node 'box (list :height '(lh 1) :width 'stretch)
                                       (list (etaf-node 'text nil
                                                        (list (plist-get it :title)))))))))
          (let ((rt (etaf-runtime-for-buffer buf)))
            ;; Initial render MUST be strictly O(viewport + 2*overscan), never 5000!
            (should (<= rendered-count 32))
            (should (string-match-p "Row #0000" (etaf-vl-tests--text buf)))
            (should-not (string-match-p "Row #2500" (etaf-vl-tests--text buf)))
            ;; Jump halfway through 5,000 rows: renders the target slice cleanly.
            (setq rendered-count 0)
            (etaf-scroll-to rt 'vl-fixed 2500)
            (should (<= rendered-count 36))
            (should (string-match-p "Row #2500" (etaf-vl-tests--text buf)))
            (should-not (string-match-p "Row #0000" (etaf-vl-tests--text buf)))
            ;; Jump to end of 5,000 rows: reaches Row #4999 cleanly.
            (setq rendered-count 0)
            (etaf-scroll-to rt 'vl-fixed 'end)
            (should (<= rendered-count 36))
            (should (string-match-p "Row #4999" (etaf-vl-tests--text buf)))
            (should scroll-events)))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-ui-virtual-list-dynamic-heights-and-scroll-anchor ()
  "Dynamic-height virtual list measures multi-line rows post-commit and keeps scroll anchored."
  (let* ((buf (generate-new-buffer " *etaf-vl-dyn*"))
         (items (cl-loop for i below 80
                         collect (list :key i
                                       :lines (if (= (% i 3) 0) 3 1)
                                       :title (format "Dyn-%02d" i)))))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (etaf-virtual-list
             :ref 'vl-dyn
             :items items
             :item-key (lambda (it) (plist-get it :key))
             :estimate-height 1
             :height 12
             :overscan 3
             :scroll-anchor 'top
             :render-item
             (lambda (it _idx _sel)
               (let ((lines (plist-get it :lines))
                     (title (plist-get it :title)))
                 (etaf-node
                  'column (list :width 'stretch :item-gap '(lh 0))
                  (cl-loop for l below lines
                           collect (etaf-node 'box (list :height '(lh 1) :width 'stretch)
                                              (list (etaf-node
                                                     'text nil
                                                     (list (format "%s-L%d" title l))))))))))))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (should (string-match-p "Dyn-00-L0" (etaf-vl-tests--text buf)))
            (should (string-match-p "Dyn-00-L2" (etaf-vl-tests--text buf)))
            (etaf-scroll-to rt 'vl-dyn 40)
            (should (> (etaf-scroll-offset rt 'vl-dyn) 0))
            (should-not (string-match-p "Dyn-00-L0" (etaf-vl-tests--text buf)))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-ui-virtual-list-keyboard-navigation-and-empty-state ()
  "Virtual list supports keyboard navigation without frame jump and renders empty states."
  (let* ((buf (generate-new-buffer " *etaf-vl-keys*"))
         (items (etaf-ref (etaf-vl-tests--items 60)))
         (selected (etaf-ref 0))
         (activated nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (etaf-virtual-list
             :ref 'vl-nav
             :items items
             :item-key (lambda (it) (plist-get it :key))
             :item-height 1
             :height 10
             :overscan 2
             :selected-key selected
             :on-select (lambda (k) (etaf-set-value selected k))
             :on-activate (lambda (k) (setq activated k))
             :empty-label "No rows available"
             :render-item (lambda (it _idx sel)
                            (etaf-node 'box (list :height '(lh 1) :width 'stretch)
                                       (list (etaf-node
                                              'text nil
                                              (list (format "%s%s"
                                                            (if sel "> " "  ")
                                                            (plist-get it :title))))))))))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (etaf-focus rt 'vl-nav)
            (should (string-match-p "> Row #0000" (etaf-vl-tests--text buf)))
            ;; Move down inside visible viewport: selection moves, offset stays 0.
            (with-current-buffer buf
              (let ((cmd (key-binding (kbd "<down>"))))
                (should cmd)
                (call-interactively cmd)))
            (should (eql 1 (etaf-value selected)))
            (should (= 0 (etaf-scroll-offset rt 'vl-nav)))
            ;; Jump to end: selects last item (59) and reveals it.
            (with-current-buffer buf
              (call-interactively (key-binding (kbd "<end>"))))
            (should (eql 59 (etaf-value selected)))
            (should (> (etaf-scroll-offset rt 'vl-nav) 0))
            (should (string-match-p "> Row #0059" (etaf-vl-tests--text buf)))
            ;; Activate current selection with RET.
            (with-current-buffer buf
              (call-interactively (key-binding (kbd "RET"))))
            (should (eql 59 activated))
            ;; Jump back home.
            (with-current-buffer buf
              (call-interactively (key-binding (kbd "<home>"))))
            (should (eql 0 (etaf-value selected)))
            (should (= 0 (etaf-scroll-offset rt 'vl-nav)))
            ;; Empty state renders cleanly when items become nil.
            (etaf-set-value items nil)
            (should (string-match-p "No rows available" (etaf-vl-tests--text buf)))))
      (ignore-errors (etaf-unmount buf))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-ui-virtual-list-5000-rows-constant-order-benchmark ()
  "Mount and scroll cost for 5,000 rows stays O(viewport) compared to 500 rows."
  (cl-labels
      ((measure (n)
         (let* ((buf (generate-new-buffer (format " *etaf-vl-bench-%d*" n)))
                (items (etaf-vl-tests--items n))
                (renders 0))
           (unwind-protect
               (let* ((t0 (float-time))
                      (_ (etaf-mount
                          buf
                          (etaf-view
                           (etaf-virtual-list
                            :ref 'vl-bench
                            :items items
                            :item-key (lambda (it) (plist-get it :key))
                            :item-height 1
                            :height 20
                            :overscan 4
                            :render-item
                            (lambda (it _idx _sel)
                              (cl-incf renders)
                              (etaf-node 'box (list :height '(lh 1) :width 'stretch)
                                         (list (etaf-node 'text nil
                                                          (list (plist-get it :title))))))))))
                      (mount-ms (* 1000.0 (- (float-time) t0)))
                      (init-renders renders)
                      (rt (etaf-runtime-for-buffer buf))
                      (t1 (float-time)))
                 (setq renders 0)
                 (dotimes (step 10)
                   (etaf-scroll-to rt 'vl-bench (* (1+ step) (/ n 12))))
                 (let ((scroll-ms (* 1000.0 (- (float-time) t1))))
                   (list :mount-ms mount-ms :scroll-ms scroll-ms
                         :init-renders init-renders :scroll-renders renders)))
             (ignore-errors (etaf-unmount buf))
             (when (buffer-live-p buf) (kill-buffer buf))))))
    (let ((r500 (measure 500))
          (r5000 (measure 5000)))
      ;; Exact O(viewport) render counts regardless of 10x data growth.
      (should (= (plist-get r500 :init-renders) (plist-get r5000 :init-renders)))
      (should (<= (plist-get r5000 :init-renders) 32))
      ;; 10 large scroll jumps on 5,000 rows must stay well under 2 seconds even in batch.
      (should (< (plist-get r5000 :scroll-ms) 2000.0)))))

(provide 'etaf-ui-virtual-list-tests)
;;; etaf-ui-virtual-list-tests.el ends here
