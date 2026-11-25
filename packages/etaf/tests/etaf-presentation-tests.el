;;; etaf-presentation-tests.el --- Runtime hooks, tree inspection and presentations -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public-API behavior checks for Runtime lifecycle hooks, read-only Host tree
;; inspection, `:translate' hints, Host press dispatch by ID, and keyed Host
;; presentation attachments (override, companion-inside, companion-after and
;; companion-beside).

;;; Code:

(require 'etaf-test-support)

(defun etaf-pres-test--buffer-text (runtime)
  "Return RUNTIME's rendered buffer text without text properties."
  (with-current-buffer (etaf-runtime-buffer runtime)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-pres-test--find-node (nodes pred)
  "Return the first node in NODES satisfying PRED in document order."
  (cl-loop for node in nodes
           for hit = (if (funcall pred node)
                         node
                       (etaf-pres-test--find-node (plist-get node :children) pred))
           when hit return hit))

(ert-deftest etaf-presentation-runtime-hooks-and-translate-prop ()
  "Runtime mount, after-commit and unmount hooks run cleanly and validate :translate."
  (let* ((events nil)
         (count (etaf-ref 0))
         (on-mount (lambda (_rt) (push 'mount events)))
         (on-commit (lambda (_rt) (push 'commit events)))
         (on-unmount (lambda (_rt) (push 'unmount events)))
         (etaf-runtime-mount-functions (list on-mount))
         (etaf-runtime-after-commit-functions (list on-commit))
         (etaf-runtime-unmount-functions (list on-unmount))
         (buf (get-buffer-create " *etaf-pres-hooks*")))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (lambda ()
             (etaf-view
              (column
               (box :translate 'no (text "code"))
               (box :translate 'content
                    (text (expr (format "count %d" (etaf-value count)))))))))
          (should (equal (nreverse (copy-sequence events)) '(mount)))
          (let* ((runtime (etaf-runtime-for-buffer buf))
                 (tree (etaf-runtime-host-tree runtime))
                 (code-box (etaf-pres-test--find-node
                            tree (lambda (n) (eq (plist-get (plist-get n :props) :translate) 'no))))
                 (content-box (etaf-pres-test--find-node
                               tree (lambda (n) (eq (plist-get (plist-get n :props) :translate) 'content)))))
            (should code-box)
            (should content-box)
            ;; Presentation-only mutations do not trigger after-commit hook.
            (etaf-runtime-set-host-presentation
             runtime (plist-get content-box :id) 'demo
             (list :mode 'companion-inside
                   :view (etaf-view (box (text "translated")))))
            (should (equal (nreverse (copy-sequence events)) '(mount)))
            ;; Application reactive write triggers after-commit hook once.
            (etaf-set-value count 1)
            (should (equal (nreverse (copy-sequence events)) '(mount commit)))
            (etaf-unmount runtime)
            (should (equal (nreverse (copy-sequence events)) '(mount commit unmount))))
          ;; Invalid :translate value signals etaf-renderer-error.
          (should-error
           (etaf-render (etaf-view (box :translate 'invalid (text "x"))))
           :type 'etaf-renderer-error))
      (when (buffer-live-p buf)
        (when-let* ((rt (etaf-runtime-for-buffer buf)))
          (ignore-errors (etaf-unmount rt)))
        (kill-buffer buf)))))

(ert-deftest etaf-presentation-text-override-preserves-authoritative-source ()
  "Text override updates painted display, preserves host-tree source, and restores cleanly."
  (let ((label (etaf-ref "Hello world")))
    (etaf-test-with-mount
        (runtime (lambda ()
                   (etaf-view (column (text :ref 'greeting (expr (etaf-value label)))))))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (text-node (etaf-pres-test--find-node
                         tree (lambda (n) (eq (plist-get n :tag) 'text))))
             (host-id (plist-get text-node :id)))
        (should (equal (plist-get text-node :text) "Hello world"))
        (should (etaf-runtime-set-host-presentation
                 runtime host-id 'translator
                 (list :mode 'override :text "你好，世界")))
        (let ((rendered (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "你好，世界" rendered))
          (should-not (string-match-p "Hello world" rendered)))
        ;; Authoritative tree still reports the application's source text.
        (let* ((tree2 (etaf-runtime-host-tree runtime))
               (node2 (etaf-pres-test--find-node
                       tree2 (lambda (n) (eql (plist-get n :id) host-id)))))
          (should (equal (plist-get node2 :text) "Hello world")))
        ;; Clearing restores original text without rerendering app state.
        (should (= 1 (etaf-runtime-clear-presentations runtime 'translator)))
        (let ((restored (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Hello world" restored)))
        ;; Re-override then mutate app ref: new authoritative text wins cleanly.
        (should (etaf-runtime-set-host-presentation
                 runtime host-id 'translator
                 (list :mode 'override :text "旧译文")))
        (etaf-set-value label "Updated text")
        (let ((after-app (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Updated text" after-app))
          (should-not (string-match-p "旧译文" after-app)))))))

(ert-deftest etaf-presentation-container-override-keeps-app-updates-and-restores ()
  "Container override parks real children, forwards updates, triggers press and restores."
  (let ((suffix (etaf-ref "originally"))
        (pressed 0))
    (etaf-test-with-mount
        (runtime
         (lambda ()
           (etaf-view
            (column :width 'stretch
              (box :ref 'para :width 'stretch :wrap-mode 'word
                (text "Read ")
                (text :role 'link :on-press (lambda () (cl-incf pressed)) "ETAF")
                (text (expr (concat " " (etaf-value suffix)))))))))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (para (etaf-pres-test--find-node
                    tree (lambda (n) (eq (plist-get n :ref) 'para))))
             (link (etaf-pres-test--find-node
                    (plist-get para :children)
                    (lambda (n) (eq (plist-get (plist-get n :props) :role) 'link))))
             (para-id (plist-get para :id))
             (link-id (plist-get link :id)))
        (should (plist-get (plist-get link :props) :has-on-press))
        ;; Replace paragraph container with translated inline runs that relay press.
        (should (etaf-runtime-set-host-presentation
                 runtime para-id 'translator
                 (list :mode 'override
                       :view (etaf-view
                              (fragment
                               (text "阅读 ")
                               (text :role 'link
                                     :on-press (lambda ()
                                                 (etaf-runtime-trigger-host-press
                                                  runtime link-id))
                                     "ETAF 手册"))))))
        (let ((rendered (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "阅读" rendered))
          (should (string-match-p "ETAF 手册" rendered))
          (should-not (string-match-p "originally" rendered)))
        ;; Triggering press by link Host ID dispatches original callback.
        (should (etaf-runtime-trigger-host-press runtime link-id))
        (should (= 1 pressed))
        ;; Mutate app child while overridden, then clear: updated child appears!
        (etaf-set-value suffix "freshly")
        (should (= 1 (etaf-runtime-clear-presentations runtime 'translator)))
        (let ((restored (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Read ETAF freshly" restored))
          (should-not (string-match-p "阅读" restored)))))))

(ert-deftest etaf-presentation-companion-inside-survives-app-updates ()
  "companion-inside appends inside a box Host, patches in place and survives child edits."
  (let ((body (etaf-ref "First sentence.")))
    (etaf-test-with-mount
        (runtime
         (lambda ()
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :ref 'p1 :width 'stretch :wrap-mode 'word
                (text (expr (etaf-value body))))
              (box :ref 'p2 :width 'stretch :wrap-mode 'word
                (text "Second paragraph."))))))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (p1 (etaf-pres-test--find-node
                  tree (lambda (n) (eq (plist-get n :ref) 'p1))))
             (p1-id (plist-get p1 :id)))
        (should (etaf-runtime-set-host-presentation
                 runtime p1-id 'translator
                 (list :mode 'companion-inside
                       :view (etaf-view (box (text "译文中…"))))))
        (let ((loading (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "First sentence\\." loading))
          (should (string-match-p "译文中…" loading))
          (should (string-match-p "Second paragraph\\." loading)))
        ;; Patch existing companion in place.
        (should (etaf-runtime-set-host-presentation
                 runtime p1-id 'translator
                 (list :mode 'companion-inside
                       :view (etaf-view (box (text "第一句话。"))))))
        (let ((done (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "第一句话。" done))
          (should-not (string-match-p "译文中…" done)))
        ;; App updates p1 text: companion stays attached cleanly.
        (etaf-set-value body "Changed sentence.")
        (let ((after-edit (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Changed sentence\\." after-edit))
          (should (string-match-p "第一句话。" after-edit)))
        ;; Clearing restores exact original layout.
        (should (= 1 (etaf-runtime-clear-presentations runtime 'translator)))
        (let ((cleared (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Changed sentence\\." cleared))
          (should-not (string-match-p "第一句话。" cleared)))))))

(ert-deftest etaf-presentation-companion-after-and-beside-preserve-list-reconciliation ()
  "companion-after and companion-beside wrap Hosts safely across keyed list updates."
  (let ((items (etaf-ref '("Alpha" "Beta"))))
    (etaf-test-with-mount
        (runtime
         (lambda ()
           (etaf-view
            (column :width 'stretch :item-gap '(lh 1)
              (box :for (item (etaf-value items)) :key item :width 'stretch
                (text (expr item))))))
         (list :viewport-width 640 :viewport-height 24))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (col (car tree))
             (first-box (car (plist-get col :children)))
             (first-id (plist-get first-box :id)))
        ;; Attach companion-after.
        (should (etaf-runtime-set-host-presentation
                 runtime first-id 'translator
                 (list :mode 'companion-after
                       :view (etaf-view (box (text "阿尔法"))))))
        (let ((stacked (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Alpha" stacked))
          (should (string-match-p "阿尔法" stacked))
          (should (string-match-p "Beta" stacked)))
        ;; Switch to companion-beside in place on the same Host.
        (should (etaf-runtime-set-host-presentation
                 runtime first-id 'translator
                 (list :mode 'companion-beside
                       :view (etaf-view (box (text "阿尔法并排"))))))
        (let ((beside (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Alpha" beside))
          (should (string-match-p "阿尔法并排" beside)))
        ;; Reorder keyed list: wrapped Host moves cleanly with its companion.
        (etaf-set-value items '("Beta" "Alpha"))
        (let ((reordered (etaf-pres-test--buffer-text runtime)))
          (should (< (string-match "Beta" reordered)
                     (string-match "Alpha" reordered)))
          (should (string-match-p "阿尔法并排" reordered)))
        ;; Remove the item: companion disposes cleanly with zero residue.
        (etaf-set-value items '("Beta"))
        (let ((removed (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Beta" removed))
          (should-not (string-match-p "Alpha" removed))
          (should-not (string-match-p "阿尔法" removed)))))))

(ert-deftest etaf-presentation-batch-skips-stale-ids-and-validates-specs ()
  "Batch presentations skip unmounted IDs and reject invalid keys or specs."
  (etaf-test-with-mount
      (runtime (etaf-view (column (box :ref 'a (text "One")))))
    (let* ((tree (etaf-runtime-host-tree runtime))
           (box-a (etaf-pres-test--find-node
                   tree (lambda (n) (eq (plist-get n :ref) 'a))))
           (id-a (plist-get box-a :id)))
      (should (= 1 (etaf-runtime-set-host-presentations
                    runtime 'translator
                    (list (cons 999999 (list :mode 'companion-after
                                             :view (etaf-view (box (text "Ghost")))))
                          (cons id-a (list :mode 'companion-inside
                                           :view (etaf-view (box (text "一")))))))))
      (should (string-match-p "一" (etaf-pres-test--buffer-text runtime)))
      (should-error
       (etaf-runtime-set-host-presentation
        runtime id-a nil (list :mode 'companion-inside
                               :view (etaf-view (box (text "x")))))
       :type 'etaf-runtime-error)
      (should-error
       (etaf-runtime-set-host-presentation
        runtime id-a 'translator (list :mode 'invalid :text "x"))
       :type 'etaf-runtime-error))))

(ert-deftest etaf-presentation-after-flush-and-live-host-geometries ()
  "after-flush hook fires on scroll (not presentations) and geometries track scroll."
  (let* ((flushes 0)
         (etaf-runtime-after-flush-functions
          (list (lambda (_rt) (cl-incf flushes))))
         (rows (cl-loop for i from 1 to 24
                        collect (format "Line %02d" i))))
    (etaf-test-with-mount
        (runtime
         (lambda ()
           (etaf-view
            (column :width 'stretch :height '(lh 8) :overflow 'scroll :ref 'scroller
              (box :for (row rows) :key row :ref (intern row) :width 'stretch
                (text (expr row))))))
         (list :viewport-width 480 :viewport-height 8))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (first-node (etaf-pres-test--find-node
                          tree (lambda (n) (equal (plist-get n :ref) (intern "Line 01")))))
             (last-node (etaf-pres-test--find-node
                         tree (lambda (n) (equal (plist-get n :ref) (intern "Line 24")))))
             (first-id (plist-get first-node :id))
             (last-id (plist-get last-node :id))
             (before (etaf-runtime-host-geometries runtime (list first-id last-id)))
             (g1 (cdr (assq first-id before)))
             (g2 (cdr (assq last-id before))))
        (should (plist-get g1 :visible-p))
        (should-not (plist-get g2 :visible-p))
        (should (= 0 (plist-get g2 :clip-top)))
        (should (= 8 (plist-get g2 :clip-bottom)))
        ;; Presentation-only mutations do not trigger after-flush-functions.
        (let ((base flushes))
          (should (etaf-runtime-set-host-presentation
                   runtime first-id 'demo
                   (list :mode 'companion-inside
                         :view (etaf-view (box (text "note"))))))
          (should (= base flushes)))
        ;; Scrolling the :overflow scroll container fires after-flush and updates :y/:visible-p.
        (let ((before-scroll flushes))
          (etaf-scroll-to runtime 'scroller 'end)
          (should (> flushes before-scroll)))
        (let* ((after (etaf-runtime-host-geometries runtime (list first-id last-id)))
               (a1 (cdr (assq first-id after)))
               (a2 (cdr (assq last-id after))))
          (should-not (plist-get a1 :visible-p))
          (should (plist-get a2 :visible-p))
          (should (< (plist-get a2 :y) (plist-get g2 :y))))))))

(ert-deftest etaf-presentation-multi-owner-coexistence-and-priority-order ()
  "Multiple presentation owners coexist on one Host in priority order and clear independently."
  (etaf-test-with-mount
      (runtime
       (etaf-view
        (column :width 'stretch
          (box :ref 'para :width 'stretch
            (text :ref 'body "Hello retained tree world"))))
       (list :viewport-width 640 :viewport-height 24))
    (let* ((tree (etaf-runtime-host-tree runtime))
           (para (etaf-pres-test--find-node
                  tree (lambda (n) (eq (plist-get n :ref) 'para))))
           (body (etaf-pres-test--find-node
                  tree (lambda (n) (eq (plist-get n :ref) 'body))))
           (para-id (plist-get para :id))
           (body-id (plist-get body :id)))
      ;; Two different owners attach companion-after with explicit priorities.
      (should (etaf-runtime-set-host-presentation
               runtime para-id 'annotator
               (list :mode 'companion-after :priority 60
                     :view (etaf-view (box (text "Note B"))))))
      (should (etaf-runtime-set-host-presentation
               runtime para-id 'translator
               (list :mode 'companion-after :priority 40
                     :view (etaf-view (box (text "Translation A"))))))
      ;; Annotator also decorates a span on the text leaf without clobbering companion.
      (should (etaf-runtime-set-host-presentation
               runtime body-id 'annotator
               (list :mode 'decorate
                     :spans (list (cons '(6 . 14)
                                        (list :face '(:background "#FEF08A")))))))
      (let ((rendered (etaf-pres-test--buffer-text runtime)))
        (should (string-match-p "Hello retained tree world" rendered))
        (should (string-match-p "Translation A" rendered))
        (should (string-match-p "Note B" rendered))
        ;; Lower priority number renders first.
        (should (< (string-match "Translation A" rendered)
                   (string-match "Note B" rendered))))
      ;; Inspect host reports both owners cleanly.
      (let* ((info (etaf-runtime-inspect-host runtime para-id))
             (keys (mapcar (lambda (p) (plist-get p :key))
                           (plist-get info :presentations))))
        (should (memq 'translator keys))
        (should (memq 'annotator keys)))
      ;; Clearing translator leaves annotator's companion and decoration intact.
      (should (= 1 (etaf-runtime-clear-presentations runtime 'translator)))
      (let ((after-tr (etaf-pres-test--buffer-text runtime)))
        (should-not (string-match-p "Translation A" after-tr))
        (should (string-match-p "Note B" after-tr)))
      ;; Clearing annotator restores both para and body cleanly.
      (should (= 2 (etaf-runtime-clear-presentations runtime 'annotator)))
      (let ((clean (etaf-pres-test--buffer-text runtime)))
        (should (string-match-p "Hello retained tree world" clean))
        (should-not (string-match-p "Note B" clean)))
      ;; Priority-stacked container overrides fall back when top owner clears.
      (should (etaf-runtime-set-host-presentation
               runtime para-id 'low-ov
               (list :mode 'override :priority 70
                     :view (etaf-view (text "Low Override")))))
      (should (etaf-runtime-set-host-presentation
               runtime para-id 'high-ov
               (list :mode 'override :priority 20
                     :view (etaf-view (text "High Override")))))
      (should (string-match-p "High Override" (etaf-pres-test--buffer-text runtime)))
      (should (= 1 (etaf-runtime-clear-presentations runtime 'high-ov)))
      (should (string-match-p "Low Override" (etaf-pres-test--buffer-text runtime)))
      (should (= 1 (etaf-runtime-clear-presentations runtime 'low-ov)))
      (should (string-match-p "Hello retained tree world"
                              (etaf-pres-test--buffer-text runtime))))))

(ert-deftest etaf-presentation-decorate-spans-survive-app-text-updates ()
  "Text decorations apply additive face spans, preserve source text and survive app updates."
  (let ((label (etaf-ref "Alpha Beta Gamma")))
    (etaf-test-with-mount
        (runtime (lambda ()
                   (etaf-view (column (text :ref 'line (expr (etaf-value label)))))))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (node (etaf-pres-test--find-node
                    tree (lambda (n) (eq (plist-get n :ref) 'line))))
             (hid (plist-get node :id)))
        (should (etaf-runtime-set-host-presentation
                 runtime hid 'hl-a
                 (list :mode 'decorate :priority 40
                       :spans (list (cons '(0 . 5)
                                          (list :face '(:background "#FEF08A")))))))
        (should (etaf-runtime-set-host-presentation
                 runtime hid 'hl-b
                 (list :mode 'decorate :priority 60
                       :spans (list (cons '(6 . 10)
                                          (list :face '(:weight bold)))))))
        ;; Check painted faces in buffer without altering authoritative host-tree text.
        (with-current-buffer (etaf-runtime-buffer runtime)
          (goto-char (point-min))
          (should (search-forward "Alpha" nil t))
          (let ((f1 (format "%S" (get-text-property (match-beginning 0) 'face))))
            (should (string-match-p "#FEF08A" f1)))
          (should (search-forward "Beta" nil t))
          (let ((f2 (format "%S" (get-text-property (match-beginning 0) 'face))))
            (should (string-match-p "bold" f2))))
        (let* ((tree2 (etaf-runtime-host-tree runtime))
               (n2 (etaf-pres-test--find-node
                    tree2 (lambda (n) (eql (plist-get n :id) hid)))))
          (should (equal (plist-get n2 :text) "Alpha Beta Gamma")))
        ;; App mutates text: decorations re-apply cleanly on the updated string.
        (etaf-set-value label "Delta Epsilon Zeta")
        (with-current-buffer (etaf-runtime-buffer runtime)
          (goto-char (point-min))
          (should (search-forward "Delta" nil t))
          (let ((f3 (format "%S" (get-text-property (match-beginning 0) 'face))))
            (should (string-match-p "#FEF08A" f3))))
        ;; Clearing hl-a via empty decorate spec keeps hl-b intact.
        (should (etaf-runtime-set-host-presentation
                 runtime hid 'hl-a (list :mode 'decorate :spans nil :face nil)))
        (with-current-buffer (etaf-runtime-buffer runtime)
          (goto-char (point-min))
          (should (search-forward "Delta" nil t))
          (let ((f4 (format "%S" (get-text-property (match-beginning 0) 'face))))
            (should-not (string-match-p "#FEF08A" f4))))))))

(ert-deftest etaf-presentation-named-root-overlays-coexist-without-commit-loop ()
  "Named root overlays coexist, patch in place, avoid commit hooks and stay out of host-tree."
  (let* ((commits 0)
         (flushes 0)
         (etaf-runtime-after-commit-functions (list (lambda (_rt) (cl-incf commits))))
         (etaf-runtime-after-flush-functions (list (lambda (_rt) (cl-incf flushes)))))
    (etaf-test-with-mount
        (runtime (etaf-view (column :width 'stretch (text "Base page")))
                 (list :viewport-width 480 :viewport-height 12))
      (let ((base-commits commits)
            (base-flushes flushes))
        (should (etaf-runtime-set-overlay
                 runtime 'hints
                 (etaf-view
                  (box :layer 'root :position 'absolute :left '(px 0) :top '(lh 2)
                       (text "HINT-A")))))
        (should (etaf-runtime-set-overlay
                 runtime 'ruler
                 (etaf-view
                  (box :layer 'root :position 'absolute :left '(px 0) :top '(lh 4)
                       (text "RULER-1")))))
        (should (= base-commits commits))
        (should (= base-flushes flushes))
        (let ((rendered (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "Base page" rendered))
          (should (string-match-p "HINT-A" rendered))
          (should (string-match-p "RULER-1" rendered)))
        ;; Overlays never pollute the application Host tree.
        (let ((tree (etaf-runtime-host-tree runtime)))
          (should-not (etaf-pres-test--find-node
                       tree (lambda (n) (equal (plist-get n :text) "HINT-A")))))
        ;; Patch one overlay in place without disturbing the other.
        (should (etaf-runtime-set-overlay
                 runtime 'hints
                 (etaf-view
                  (box :layer 'root :position 'absolute :left '(px 0) :top '(lh 2)
                       (text "HINT-B")))))
        (let ((patched (etaf-pres-test--buffer-text runtime)))
          (should (string-match-p "HINT-B" patched))
          (should-not (string-match-p "HINT-A" patched))
          (should (string-match-p "RULER-1" patched)))
        ;; Clear single overlay, then clear remaining overlays.
        (should (= 1 (etaf-runtime-clear-overlay runtime 'hints)))
        (let ((after-one (etaf-pres-test--buffer-text runtime)))
          (should-not (string-match-p "HINT-B" after-one))
          (should (string-match-p "RULER-1" after-one)))
        (should (= 1 (etaf-runtime-clear-overlay runtime)))
        (should-not (string-match-p "RULER-1" (etaf-pres-test--buffer-text runtime)))))))

(ert-deftest etaf-presentation-runtime-meta-and-reactive-meta-hook ()
  "Runtime metadata mounts before mount hooks, tracks reactive refs and notifies observers."
  (let* ((uri (etaf-ref "https://example.org/a"))
         (mount-meta nil)
         (meta-events nil)
         (etaf-runtime-mount-functions
          (list (lambda (rt) (setq mount-meta (etaf-runtime-meta rt)))))
         (etaf-runtime-meta-change-functions
          (list (lambda (_rt meta) (push meta meta-events))))
         (buf (etaf-app-open " *etaf-meta-test*"
                             (etaf-view (text "Article"))
                             :display nil
                             :meta (list :app 'etaf-web :kind 'document :uri uri))))
    (unwind-protect
        (let ((rt (etaf-runtime-for-buffer buf)))
          (should (eq (plist-get mount-meta :app) 'etaf-web))
          (should (equal (plist-get mount-meta :uri) "https://example.org/a"))
          (should (null meta-events))
          ;; Reactive ref write fires meta-change hook once.
          (etaf-set-value uri "https://example.org/b")
          (should (= 1 (length meta-events)))
          (should (equal (plist-get (car meta-events) :uri) "https://example.org/b"))
          (should (equal (plist-get (etaf-runtime-meta rt) :uri) "https://example.org/b"))
          ;; Explicit etaf-runtime-set-meta replaces metadata and fires hook.
          (etaf-runtime-set-meta rt (list :app 'etaf-web :uri "https://example.org/c"))
          (should (= 2 (length meta-events)))
          (should (equal (plist-get (etaf-runtime-meta rt) :uri) "https://example.org/c"))
          (etaf-app-close buf)
          ;; Updates after unmount do not fire stale watchers.
          (etaf-set-value uri "https://example.org/d")
          (should (= 2 (length meta-events))))
      (when (buffer-live-p buf)
        (ignore-errors (etaf-app-close buf))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest etaf-presentation-semantic-actions-text-offset-and-key-layers ()
  "Semantic Host focus/scroll/text-offset and extension key layers honor priority and help."
  (let* ((focus-log nil)
         (app-hit 0)
         (ext-hit 0)
         (etaf-runtime-focus-change-functions
          (list (lambda (_rt prev next) (push (cons prev next) focus-log)))))
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column :width 'stretch
                  :keys (list (list "C-c z" (lambda () (cl-incf app-hit)) "App Z"))
            (box :ref 'btn1 :tab-index 0 :on-press #'ignore (text "Button One"))
            (box :ref 'btn2 :tab-index 0 :on-press #'ignore (text "Button Two"))
            (text :ref 'sample "Hello Emacs ETAF")))
         (list :viewport-width 480 :viewport-height 12 :text-selection t))
      (let* ((tree (etaf-runtime-host-tree runtime))
             (b1 (etaf-pres-test--find-node tree (lambda (n) (eq (plist-get n :ref) 'btn1))))
             (b2 (etaf-pres-test--find-node tree (lambda (n) (eq (plist-get n :ref) 'btn2))))
             (tx (etaf-pres-test--find-node tree (lambda (n) (eq (plist-get n :ref) 'sample))))
             (id1 (plist-get b1 :id))
             (id2 (plist-get b2 :id))
             (tx-id (plist-get tx :id)))
        ;; Semantic focus dispatches focus-change hook with Host IDs.
        (should (etaf-runtime-focus-host runtime id1))
        (should (etaf-runtime-focus-host runtime id2))
        (should (equal (car focus-log) (cons id1 id2)))
        (should (etaf-runtime-scroll-host-into-view runtime id2))
        ;; Text offset and active region mapping inside a text Host.
        (with-current-buffer (etaf-runtime-buffer runtime)
          (goto-char (point-min))
          (should (search-forward "Emacs" nil t))
          (let* ((pos (match-beginning 0))
                 (info (etaf-runtime-host-text-offset-at runtime pos)))
            (should (eql (plist-get info :id) tx-id))
            (should (= 6 (plist-get info :offset)))
            (should (equal (plist-get info :text) "Hello Emacs ETAF")))
          (set-mark (match-beginning 0))
          (goto-char (match-end 0))
          (let ((transient-mark-mode t))
            (activate-mark)
            (let ((rinfo (etaf-runtime-host-text-offset-at runtime)))
              (should (equal (plist-get rinfo :region) '(6 . 11)))))
          (deactivate-mark))
        ;; Extension key layers reject reserved keys, yield to App keys and show in help.
        (should-error
         (etaf-runtime-set-key-layer runtime 'bad (list (list "?" #'ignore "Bad")))
         :type 'etaf-runtime-error)
        (should (etaf-runtime-set-key-layer
                 runtime 'demo-ext
                 (list (list "C-c z" (lambda () (cl-incf ext-hit)) "Shadowed Ext Z")
                       (list "C-c y" (lambda () (cl-incf ext-hit)) "Ext Y"))
                 "Demo Ext"))
        (save-window-excursion
          (set-window-buffer (selected-window) (etaf-runtime-buffer runtime))
          (with-current-buffer (etaf-runtime-buffer runtime)
            (execute-kbd-macro (kbd "C-c z"))
            (should (= 1 app-hit))
            (should (= 0 ext-hit))
            (execute-kbd-macro (kbd "C-c y"))
            (should (= 1 ext-hit))))
        (let* ((hdata (etaf-help-data runtime))
               (ext-group (cl-find 'extension (plist-get hdata :groups)
                                   :key (lambda (g) (plist-get g :kind)))))
          (should ext-group)
          (should (cl-some (lambda (e) (equal (plist-get e :label) "Ext Y"))
                           (plist-get ext-group :entries)))
          (should-not (cl-some (lambda (e) (equal (plist-get e :label) "Shadowed Ext Z"))
                               (plist-get ext-group :entries))))
        (should (= 1 (etaf-runtime-clear-key-layer runtime 'demo-ext)))))))

(provide 'etaf-presentation-tests)
;;; etaf-presentation-tests.el ends here
