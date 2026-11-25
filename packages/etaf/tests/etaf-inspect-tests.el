;;; etaf-inspect-tests.el --- Public Runtime introspection API tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public-API behavior checks for `etaf-runtime-list',
;; `etaf-runtime-inspect-tree', `etaf-runtime-host-id-at',
;; `etaf-runtime-inspect-host', `etaf-runtime-inspect-component',
;; `etaf-runtime-set-component-binding', `etaf-runtime-inspect-focus' and
;; `etaf-runtime-commit-summary'.

;;; Code:

(require 'etaf-test-support)

(etaf-define-component etaf-inspect-test-card (&key (title "Default"))
  :bindings ((clicks (etaf-ref 1 :name 'clicks))
             (label (etaf-computed (lambda () (format "%s:%d" title (etaf-value clicks)))
                                   :name 'label)))
  :styles (("&.card" :padding ((lh 1) (ch 2)) :color "#ffffff"))
  :view (box :id "card" :class "card" :ref 'card-box :tab-index 0
             :aria-label "Inspect Card"
             :on-press (lambda () (etaf-update-value clicks #'1+))
             (text :ref 'card-text (expr (etaf-value label)))))

(defun etaf-inspect-test--find (nodes pred)
  "Return the first node in NODES satisfying PRED in document order."
  (cl-loop for node in nodes
           for hit = (if (funcall pred node)
                         node
                       (etaf-inspect-test--find (plist-get node :children) pred))
           when hit return hit))

(ert-deftest etaf-inspect-tree-and-runtime-list-track-mounted-runtimes ()
  "Live Runtimes appear in `etaf-runtime-list' and expose Component+Host trees."
  (let* ((buf (generate-new-buffer " *etaf-inspect-tree*"))
         (view (etaf-view (column :width '(ch 40)
                                  (etaf-inspect-test-card :title "Alpha")))))
    (unwind-protect
        (progn
          (etaf-mount buf view '(:viewport-width 320 :viewport-height 20))
          (let* ((rt (etaf-runtime-for-buffer buf))
                 (listed (etaf-runtime-list))
                 (tree (etaf-runtime-inspect-tree rt))
                 (comp (etaf-inspect-test--find
                        tree (lambda (n) (and (eq (plist-get n :kind) 'component)
                                              (eq (plist-get n :name) 'etaf-inspect-test-card)))))
                 (host (etaf-inspect-test--find
                        tree (lambda (n) (and (eq (plist-get n :kind) 'host)
                                              (equal (plist-get n :dom-id) "card"))))))
            (should (memq rt listed))
            (should comp)
            (should host)
            (should (integerp (plist-get comp :id)))
            (should (equal (plist-get host :classes) '("card")))
            (should (memq (plist-get host :id) (plist-get comp :root-host-ids))))
          (etaf-unmount (etaf-runtime-for-buffer buf))
          (should-not (cl-find buf (etaf-runtime-list) :key #'etaf-runtime-buffer)))
      (when (buffer-live-p buf)
        (ignore-errors (etaf-unmount (etaf-runtime-for-buffer buf)))
        (kill-buffer buf)))))

(ert-deftest etaf-inspect-host-and-point-hit-return-metrics-style-and-spans ()
  "Point hit resolves Host IDs and `etaf-runtime-inspect-host' returns full snapshots."
  (let* ((buf (generate-new-buffer " *etaf-inspect-host*"))
         (view (etaf-view (column :width '(ch 40)
                                  (etaf-inspect-test-card :title "Beta")))))
    (unwind-protect
        (progn
          (etaf-mount buf view '(:viewport-width 320 :viewport-height 20))
          (let* ((rt (etaf-runtime-for-buffer buf))
                 (tree (etaf-runtime-inspect-tree rt))
                 (card (etaf-inspect-test--find
                        tree (lambda (n) (and (eq (plist-get n :kind) 'host)
                                              (equal (plist-get n :dom-id) "card")))))
                 (cid (plist-get card :id))
                 (info (etaf-runtime-inspect-host rt cid))
                 (pos (etaf-host-ref-position rt 'card-text))
                 (hit-ids (etaf-runtime-host-id-at rt pos))
                 (style (plist-get info :style))
                 (rules (plist-get style :matched-rules))
                 (card-rule (cl-find-if (lambda (r) (equal (plist-get r :selector) "&.card")) rules))
                 (metrics (plist-get info :box-metrics))
                 (spans (plist-get info :row-spans)))
            (should info)
            (should (eq (plist-get info :owner-component-name) 'etaf-inspect-test-card))
            (should (plist-get info :focusable-p))
            (should (plist-get info :has-press-p))
            (should metrics)
            (should (= (plist-get (plist-get metrics :padding) :top) 1))
            (should card-rule)
            (should (eq (plist-get card-rule :owner-component-name) 'etaf-inspect-test-card))
            (should-not (plist-member card-rule :scope-root))
            (should (consp spans))
            (should (memq cid hit-ids))))
      (when (buffer-live-p buf)
        (ignore-errors (etaf-unmount (etaf-runtime-for-buffer buf)))
        (kill-buffer buf)))))

(ert-deftest etaf-inspect-component-bindings-and-live-ref-mutation ()
  "Component inspection reports named bindings and allows controlled `etaf-ref' writes."
  (let* ((buf (generate-new-buffer " *etaf-inspect-comp*"))
         (view (etaf-view (column :width '(ch 40)
                                  (etaf-inspect-test-card :title "Live")))))
    (unwind-protect
        (progn
          (etaf-mount buf view '(:viewport-width 320 :viewport-height 20))
          (let* ((rt (etaf-runtime-for-buffer buf))
                 (tree (etaf-runtime-inspect-tree rt))
                 (comp (etaf-inspect-test--find
                        tree (lambda (n) (and (eq (plist-get n :kind) 'component)
                                              (eq (plist-get n :name) 'etaf-inspect-test-card)))))
                 (iid (plist-get comp :id))
                 (snap1 (etaf-runtime-inspect-component rt iid))
                 (bindings1 (plist-get snap1 :bindings))
                 (clicks-b (cl-find 'clicks bindings1 :key (lambda (b) (plist-get b :name))))
                 (label-b (cl-find 'label bindings1 :key (lambda (b) (plist-get b :name)))))
            (should clicks-b)
            (should (eq (plist-get clicks-b :kind) 'ref))
            (should (plist-get clicks-b :editable-p))
            (should (= (plist-get clicks-b :value) 1))
            (should label-b)
            (should (eq (plist-get label-b :kind) 'computed))
            (should-not (plist-get label-b :editable-p))
            ;; Mutate clicks ref through controlled public API
            (should (eq t (etaf-runtime-set-component-binding rt iid 'clicks 42)))
            (let ((text (with-current-buffer buf
                          (buffer-substring-no-properties (point-min) (point-max))))
                  (summary (etaf-runtime-commit-summary rt)))
              (should (string-match-p "Live:42" text))
              (should (>= (plist-get summary :rev) 2))
              (should (plist-get summary :update-report)))
            ;; Reject writing to non-ref computed binding
            (should-error (etaf-runtime-set-component-binding rt iid 'label "bad")
                          :type 'etaf-runtime-error)))
      (when (buffer-live-p buf)
        (ignore-errors (etaf-unmount (etaf-runtime-for-buffer buf)))
        (kill-buffer buf)))))

(ert-deftest etaf-inspect-focus-reports-stops-regions-and-help ()
  "`etaf-runtime-inspect-focus' summarizes focus state, Tab stops, regions and keys."
  (let* ((buf (generate-new-buffer " *etaf-inspect-focus*"))
         (view (etaf-view
                (column :width '(ch 40)
                        :region '(:id main :label "Main" :key ?m :enter card-box)
                        :keys `(("x" ,(lambda () nil) "Custom action"))
                        (etaf-inspect-test-card :title "Focus")))))
    (unwind-protect
        (progn
          (etaf-mount buf view '(:viewport-width 320 :viewport-height 20))
          (let ((rt (etaf-runtime-for-buffer buf)))
            (etaf-focus rt 'card-box)
            (let* ((finfo (etaf-runtime-inspect-focus rt))
                   (stops (plist-get finfo :stops))
                   (regions (plist-get finfo :regions))
                   (help (plist-get finfo :help)))
              (should (integerp (plist-get finfo :focused-host-id)))
              (should (eq (plist-get finfo :focused-host-ref) 'card-box))
              (should (= (length stops) 1))
              (should (plist-get (car stops) :focused-p))
              (should (= (length regions) 1))
              (should (eq (plist-get (car regions) :id) 'main))
              (should (plist-get help :groups)))))
      (when (buffer-live-p buf)
        (ignore-errors (etaf-unmount (etaf-runtime-for-buffer buf)))
        (kill-buffer buf)))))

(provide 'etaf-inspect-tests)
;;; etaf-inspect-tests.el ends here
