;;; ebox-update-tests.el --- Ebox retained update behaviour tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-mount-exposes-root-buffer-and-viewport ()
  (ebox-test-with-mounted (buffer root '(box :width (vw 50) :height (lh 1)))
    (should (eq (ebox-buffer-root buffer) root))
    (should (eq (ebox-node-buffer root) buffer))
    (should (equal (ebox-mount-viewport buffer) '(80 . nil)))
    (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 40 :height 1)))
    (ebox-mount-set-viewport buffer 20 5)
    (should (equal (ebox-mount-viewport buffer) '(20 . 5)))
    (should (equal (ebox-node-geometry root) '(:x 0 :y 0 :width 10 :height 1)))
    (should (ebox-test-buffer-matches-render-p root buffer))))

(ert-deftest ebox-viewport-change-hook-reports-settled-size ()
  (ebox-test-with-mounted (buffer root '(box :width (vw 50) :height (lh 1)))
    (let* ((seen nil)
           (hook (lambda (changed)
                   (push (list changed (ebox-mount-viewport changed)
                               (plist-get (ebox-node-geometry root) :width))
                         seen))))
      (add-hook 'ebox-viewport-change-functions hook)
      (unwind-protect
          (progn
            (ebox-mount-set-viewport buffer 20 5)
            (ebox-mount-set-viewport buffer 20 5)
            (should (equal seen (list (list buffer '(20 . 5) 10)))))
        (remove-hook 'ebox-viewport-change-functions hook)))))

;; Emacs runs `window-size-change-functions' only in an interactive session,
;; so the scenario binds `noninteractive' around the hook it would run.
(defun ebox-test-settle-window-change ()
  "Deliver a window size change for the selected frame and let it settle."
  (let ((noninteractive nil))
    (run-hook-with-args 'window-size-change-functions (selected-frame)))
  (sleep-for (+ ebox-viewport-settle-delay 0.1)))

(ert-deftest ebox-display-window-change-hook-follows-the-window ()
  (let ((buffer (get-buffer-create " *ebox-display-window*"))
        (config (current-window-configuration))
        (seen nil))
    (let ((hook (lambda (changed window)
                  (push (list changed (eq window (get-buffer-window changed))
                              (window-body-height window))
                        seen))))
      (unwind-protect
          (progn
            (delete-other-windows)
            (set-window-buffer (selected-window) buffer)
            ;; A fixed viewport keeps the layout, yet the window still changes.
            (ebox-mount buffer '(box :height (lh 1) "x"))
            (ebox-mount-set-viewport buffer nil 3)
            (add-hook 'ebox-display-window-change-functions hook)
            (ebox-test-settle-window-change)
            (let ((full (window-body-height)))
              (should (equal seen (list (list buffer t full))))
              (setq seen nil)
              (ebox-test-settle-window-change)
              (should-not seen)
              (split-window)
              (ebox-test-settle-window-change)
              (should (equal (length seen) 1))
              (should (< (nth 2 (car seen)) full))
              (should (equal (ebox-mount-viewport buffer)
                             (cons (car (ebox-mount-viewport buffer)) 3)))))
        (remove-hook 'ebox-display-window-change-functions hook)
        (set-window-configuration config)
        (kill-buffer buffer)))))

(ert-deftest ebox-mount-viewport-follows-displaying-window ()
  (let ((buffer (get-buffer-create " *ebox-viewport-window*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (let ((prospective (ebox-viewport-measure buffer)))
            (should (equal (ebox-viewport-measure buffer 33 7) '(33 . 7)))
            (ebox-mount buffer '(box :height (vh 100) "x"))
            (should (equal (ebox-mount-viewport buffer) prospective)))
          (should (equal (ebox-mount-viewport buffer)
                         (cons (ebox-viewport-window-width (selected-window))
                               (window-body-height (selected-window)))))
          (should (equal (plist-get (ebox-node-geometry (ebox-buffer-root buffer)) :height)
                         (window-body-height (selected-window)))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-first-content-keeps-point-and-window-start-at-top ()
  (let ((buffer (get-buffer-create " *ebox-first-content*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (let* ((root (ebox-mount buffer '(column :id "list")))
                 (window (selected-window)))
            (should (= (buffer-size buffer) 0))
            (ebox-node-insert root (ebox-build '(column (box "One") (box "Two") (box "Three"))))
            (with-current-buffer buffer
              (should (equal (ebox-test-buffer-text buffer) "One \nTwo \nThree "))
              (should (= (point) (point-min))))
            (should (= (window-point window) 1))
            (should (= (window-start window) 1))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-refit-returns-a-fitting-tree-to-the-window-top ()
  (let ((buffer (get-buffer-create " *ebox-refit-start*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (ebox-mount buffer '(column (box "One") (box "Two") (box "Three")))
          (let ((window (selected-window)))
            ;; A borrowed, shorter window scrolled the tree; it fits again.
            (set-window-start window (with-current-buffer buffer
                                       (save-excursion (goto-char (point-min))
                                                       (forward-line 1) (point))))
            (ebox-refit buffer)
            (should (= (window-start window) 1))))
      (set-window-configuration config)
      (kill-buffer buffer))))

(ert-deftest ebox-mounted-rows-own-wrapping-and-restore-buffer-settings ()
  "A mounted buffer cannot wrap engine rows again; unmount restores its policy."
  (dolist (initial '(inherit nil t))
    (with-temp-buffer
      ;; `truncate-lines' is automatically buffer-local: setting it creates
      ;; the local binding on both Emacs 29 and 30+, unlike the let-binding
      ;; plus `make-local-variable' combination whose interaction changed in
      ;; Emacs 30.
      (unless (eq initial 'inherit)
        (setq-local truncate-lines initial))
      (let ((was-local (local-variable-p 'truncate-lines))
            (before truncate-lines))
        (ebox-mount (current-buffer) '(box :width (px 400) "Already laid out")
                    :width 400 :height 2)
        (should truncate-lines)
        (should (local-variable-p 'truncate-lines))
        (ebox-unmount-buffer (current-buffer))
        (should (eq before truncate-lines))
        (should (eq was-local (local-variable-p 'truncate-lines)))))))

(ert-deftest ebox-buffer-background-follows-root-background ()
  (let ((buffer (get-buffer-create " *ebox-canvas*")))
    (unwind-protect
        (let ((root (ebox-mount buffer '(column :background-color "#101820" "x"))))
          (with-current-buffer buffer
            (should (equal (cdr (assq 'default face-remapping-alist))
                           '((:background "#101820") default))))
          (ebox-node-put root :background-color "#203040")
          (with-current-buffer buffer
            (should (equal (cdr (assq 'default face-remapping-alist))
                           '((:background "#203040") default))))
          (ebox-unmount-buffer buffer)
          (with-current-buffer buffer
            (should-not (cdr (assq 'default face-remapping-alist)))))
      (kill-buffer buffer))))

(ert-deftest ebox-node-set-text-updates-buffer-like-fresh-render ()
  (ebox-test-with-mounted (buffer root '(column (text :id "value" "One") (box "Tail")))
    (let ((value (car (ebox-selector-query root "#value"))))
      (ebox-node-set-text value "Two")
      (should (equal (ebox-test-buffer-text buffer) "Two 
Tail "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-node-put-and-set-props-restyle-visible-content ()
  (ebox-test-with-mounted (buffer root '(box :id "panel" :width (ch 4) "A"))
    (let ((panel (car (ebox-selector-query root "#panel"))))
      (ebox-node-put panel :color "#123456")
      (should (equal (get-text-property (point-min) 'face)
                     '(:foreground "#123456")))
      (ebox-node-set-props panel '(:id "panel" :width (ch 4) :background-color "#abcdef"))
      (should (equal (get-text-property (point-min) 'face)
                     '(:background "#abcdef")))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-parent-restyle-updates-inheriting-descendants ()
  (ebox-test-with-mounted
      (buffer root '(column :id "p" :padding-left (ch 1) :color "#111111"
                            (box :id "a" "A") (box :color "#222222" "B")))
    (let ((p (car (ebox-selector-query root "#p")))
          (a (car (ebox-selector-query root "#a"))))
      (ebox-node-put p :padding-left '(ch 2))
      (should (equal (ebox-node-geometry a) '(:x 2 :y 0 :width 78 :height 1)))
      (should (equal (get-text-property (1+ (point-min)) 'face)
                     '(:foreground "#111111")))
      (ebox-node-put p :color "#333333")
      (should (equal (get-text-property (1+ (point-min)) 'face)
                     '(:foreground "#333333")))
      (should (ebox-test-buffer-matches-render-p root buffer))))
  (ebox-test-with-mounted
      (buffer root `(column :id "p" :padding-left (ch 1)
                            (box :padding-left ,(ecss-wide-value 'inherit)
                                 (box :id "a" "A"))))
    (let ((p (car (ebox-selector-query root "#p")))
          (a (car (ebox-selector-query root "#a"))))
      (should (equal (ebox-node-geometry a) '(:x 2 :y 0 :width 78 :height 1)))
      (ebox-node-put p :padding-left '(ch 3))
      (should (equal (ebox-node-geometry a) '(:x 6 :y 0 :width 74 :height 1)))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-scope-root-rule-change-restyles-members ()
  (let* ((old (ebox-style-scope-create '((".accent" :color "#ff0000"))))
         (new (ebox-style-scope-with-rules old '((".accent" :color "#0000ff")))))
    (ebox-test-with-mounted
        (buffer root `(column :id "root" :ecss-scope-roots (,old)
                              (box (box :class "accent" :ecss-scopes (,old) "A"))))
      (should (equal (get-text-property (point-min) 'face) '(:foreground "#ff0000")))
      (ebox-node-put root :ecss-scope-roots (list new))
      (should (equal (get-text-property (point-min) 'face) '(:foreground "#0000ff")))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-node-insert-remove-move-and-replace-children-update-order ()
  (ebox-test-with-mounted (buffer root '(column :width (ch 2) (box :id "a" "A") (box :id "b" "B")))
    (let* ((a (car (ebox-selector-query root "#a")))
           (b (car (ebox-selector-query root "#b")))
           (c (ebox-node-create 'box '(:id "c") '("C"))))
      (ebox-node-insert root c 1)
      (should (equal (ebox-test-buffer-text buffer) "A 
C 
B "))
      (ebox-node-move b 0)
      (should (equal (ebox-test-buffer-text buffer) "B 
A 
C "))
      (ebox-node-remove a)
      (should (equal (ebox-test-buffer-text buffer) "B 
C "))
      (ebox-node-replace-children root (list c "D"))
      (should (equal (ebox-test-buffer-text buffer) "C 
D "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-shrunk-flex-item-update-keeps-following-siblings ()
  (ebox-test-with-mounted
      (buffer root '(flex :flex-direction column :height (lh 6)
                          (column :flex-grow 1 :min-height (lh 0)
                                  (column :height (% 100) "x")
                                  (column :id "list" "1" "2" "3" "4" "5" "6" "7"))
                          (box "T") (box "F")))
    (ebox-node-insert (car (ebox-selector-query root "#list")) "8")
    (should (equal (split-string (ebox-test-buffer-text buffer) "\n") '("x " " " " " " " "T " "F ")))
    (should (ebox-test-buffer-matches-render-p root buffer))))

(ert-deftest ebox-with-batch-flushes-mutated-mount-once ()
  (ebox-test-with-mounted (buffer root '(column (text :id "a" "A") (text :id "b" "B")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b")))
          (before (ebox-mount-flush-count buffer)))
      (ebox-with-batch
        (ebox-node-set-text a "AA")
        (ebox-node-set-text b "BB")
        (should (= (ebox-mount-flush-count buffer) before)))
      (should (= (ebox-mount-flush-count buffer) (1+ before)))
      (should (equal (ebox-test-buffer-text buffer) "AA 
BB "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-call-with-batch-returns-body-value ()
  (ebox-test-with-mounted (buffer root '(box (text :id "value" "A")))
    (let ((value (car (ebox-selector-query root "#value"))))
      (should (equal (ebox-call-with-batch
                      (lambda ()
                        (ebox-node-set-text value "B")
                        :done))
                     :done))
      (should (equal (ebox-test-buffer-text buffer) "B ")))))

(ert-deftest ebox-flush-reports-and-observers-describe-public-update ()
  (ebox-test-with-mounted (buffer root '(box (text :id "value" "A")))
    (let ((value (car (ebox-selector-query root "#value")))
          seen)
      (ebox-buffer-set-observer
       buffer (lambda (observed-buffer report)
                (setq seen (list observed-buffer report))))
      (ebox-node-set-text value "B")
      (let ((report (ebox-buffer-update-report buffer)))
        (should (eq (car seen) buffer))
        (should (equal (cadr seen) report))
        (should (eq (plist-get report :provider) 'ebox))
        (should (eq (plist-get report :strategy) 'lines))
        (should (= (plist-get report :edits) 1))
        (should (= (plist-get report :flush) (ebox-mount-flush-count buffer)))))))

(ert-deftest ebox-after-flush-hook-runs-with-updated-buffer ()
  (ebox-test-with-mounted (buffer root '(box (text :id "value" "A")))
    (let ((value (car (ebox-selector-query root "#value")))
          seen)
      (let ((ebox-after-flush-functions
             (list (lambda (flushed-buffer)
                     (setq seen (cons flushed-buffer (ebox-test-buffer-text flushed-buffer)))))))
        (ebox-node-set-text value "B"))
      (should (equal seen (cons buffer "B "))))))

(ert-deftest ebox-unmount-runs-hook-and-releases-mount ()
  (let ((buffer (generate-new-buffer " *ebox-unmount-test*")) seen)
    (unwind-protect
        (progn
          (ebox-mount buffer '(box "A"))
          (let ((ebox-unmount-functions (list (lambda (unmounted) (setq seen unmounted)))))
            (should (ebox-unmount-buffer buffer)))
          (should (eq seen buffer))
          (should-not (ebox-buffer-mount buffer))
          (should (equal (ebox-test-buffer-text buffer) "A ")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-kill-buffer-runs-unmount-hook ()
  "Killing a mounted buffer runs the unmount hooks before it dies."
  (let ((buffer (generate-new-buffer " *ebox-kill-test*")) seen)
    (unwind-protect
        (progn
          (ebox-mount buffer '(box "A"))
          (let ((ebox-unmount-functions (list (lambda (unmounted) (setq seen unmounted)))))
            (kill-buffer buffer))
          (should (eq seen buffer))
          (should-not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ebox-node-mutation-errors-leave-buffer-at-last-successful-render ()
  (ebox-test-with-mounted (buffer root '(column (box :id "a" "A") (box :id "b" "B")))
    (let ((a (car (ebox-selector-query root "#a")))
          (b (car (ebox-selector-query root "#b"))))
      (should-error (ebox-node-insert a b) :type 'ebox-error)
      (should (equal (ebox-test-buffer-text buffer) "A 
B "))
      (should-error (ebox-node-set-text a "not text") :type 'ebox-error)
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-restyle-preserves-characters-and-interior-markers ()
  "Restyling several adjacent parts keeps text and native markers in place."
  (ebox-test-with-mounted
      (buffer root '(row :width (ch 40)
                        (text "LEFT")
                        (row :id "middle" :color "#123456"
                             (text "甲乙") (text "middle") (text "丙丁"))
                        (text "RIGHT")))
    (let* ((middle (car (ebox-selector-query root "#middle")))
           (text (ebox-test-buffer-text buffer))
           (tick (buffer-chars-modified-tick))
           (position (+ (point-min) (string-match "middle" text) 3))
           (marker (copy-marker position)))
      (unwind-protect
          (dolist (color '("#abcdef" "#345678" "#123456"))
            (ebox-node-put middle :color color)
            (should (equal (ebox-test-buffer-text buffer) text))
            (should (= (buffer-chars-modified-tick) tick))
            (should (= (marker-position marker) position))
            (should (equal (plist-get (get-text-property position 'face)
                                      :foreground)
                           color)))
        (set-marker marker nil)))))

(ert-deftest ebox-text-update-preserves-common-prefix-and-suffix-markers ()
  "A local edit leaves markers in its unchanged text and neighbors intact."
  (ebox-test-with-mounted
      (buffer root '(row :width (ch 60)
                        (text "LEFT") (text :id "value" "pre OLD tail")
                        (text "RIGHT")))
    (let* ((value (car (ebox-selector-query root "#value")))
           (start (ebox-node-position value))
           (prefix (copy-marker (1+ start)))
           (suffix (copy-marker (+ start 9))))
      (unwind-protect
          (dolist (word '("NEWER" "新" "" "OLD"))
            (ebox-node-set-text value (concat "pre " word " tail"))
            (should (= (marker-position prefix) (1+ start)))
            (should (= (char-after prefix) ?r))
            (should (= (char-after suffix) ?a))
            (should (= (marker-position suffix) (+ start 6 (length word))))
            (should (string-prefix-p "LEFTpre " (ebox-test-buffer-text buffer)))
            (should (string-match-p " tailRIGHT" (ebox-test-buffer-text buffer))))
        (set-marker prefix nil)
        (set-marker suffix nil)))))

(ert-deftest ebox-next-publication-repairs-foreign-text-and-properties ()
  "A changed row is repaired from its tree, not from remembered buffer output."
  (ebox-test-with-mounted
      (buffer root '(row :width (ch 40)
                        (text :color "#123456" "LEFT")
                        (text :id "value" "old") (text "RIGHT")))
    (let ((value (car (ebox-selector-query root "#value"))))
      (dolist (text '("new" "old"))
        (let ((inhibit-read-only t))
          (put-text-property (point-min) (+ (point-min) 2) 'face
                             '(:foreground "#abcdef"))
          (goto-char (+ (point-min) 2))
          (insert "foreign"))
        (ebox-node-set-text value text)
        (should (string-prefix-p (concat "LEFT" text "RIGHT")
                                 (ebox-test-buffer-text buffer)))
        (should (equal (get-text-property (point-min) 'face)
                       '(:foreground "#123456")))))))

(ert-deftest ebox-property-update-keeps-native-display-and-keymap-identity ()
  "Property-only writes keep adjacent display twins and the new input objects."
  (let* ((display (list 'space :width '(4)))
         (hits 0)
         (map (ebox-keymap-create :activate (lambda () (cl-incf hits))))
         (replacement (copy-keymap map)))
    (ebox-test-with-mounted
        (buffer root `(row :width (ch 40)
                           (text ,(propertize "a" 'display display))
                           (text :id "middle" :keymap ,map :help-echo "old"
                                 ,(propertize "b" 'display display))
                           (text ,(propertize "c" 'display display))))
      (let ((middle (car (ebox-selector-query root "#middle"))))
        ;; The help change publishes the replacement map even when its
        ;; bindings compare equal to the earlier map.
        (ebox-node-set-props middle (list :id "middle" :keymap replacement
                                          :help-echo "new"))
        (dotimes (i 2)
          (should-not (eq (get-text-property (+ (point-min) i) 'display)
                          (get-text-property (+ (point-min) i 1) 'display))))
        (should (string-prefix-p "abc" (ebox-test-buffer-text buffer)))
        (let* ((position (1+ (point-min)))
               (current-map (get-text-property position 'keymap))
               (same-map (eq current-map replacement)))
          (should same-map)
          (should (equal (get-text-property position 'help-echo) "new"))
          (ebox-activate position)
          (should (= hits 1)))
        (ebox-node-set-props middle '(:id "middle" :keymap nil :help-echo nil))
        (let* ((position (1+ (point-min)))
               (retired-map (get-text-property position 'keymap)))
          (should-not (lookup-key retired-map (kbd "RET")))
          (should-not (get-text-property position 'help-echo))
          (ebox-activate position t)
          (should (= hits 1)))))))

(ert-deftest ebox-overlay-local-updates-publish-only-the-changed-row ()
  "A stable overlay publishes a local paint or text change independently of height."
  (dolist (height '(6 60))
    (ebox-test-with-mounted
        (buffer root
                `(column :width (ch 40) :height (lh ,(+ height 4))
                         (box "Underlay")
                         (box :position absolute :layer root :top (lh 2) :left (ch 3)
                              :width (ch 24) :height (lh ,height)
                              :backdrop-filter (brightness 0.5)
                              (column (text "Header")
                                      (text :id "subject" "Before")
                                      (text :id "footer" "Footer")))))
      (let* ((subject (car (ebox-selector-query root "#subject")))
             (footer (car (ebox-selector-query root "#footer")))
             (position (ebox-node-position footer))
             (marker (copy-marker (1+ position))))
        (unwind-protect
            (dolist (change (list (lambda () (ebox-node-put subject :color "#A02030"))
                                 (lambda () (ebox-node-set-text subject "After!"))))
              (funcall change)
              (let ((report (ebox-buffer-update-report buffer))
                    (matches (ebox-test-buffer-matches-render-p root buffer)))
                (should (> (plist-get report :lines) 0))
                (should (<= (plist-get report :lines) 1))
                (should matches))
              (should (= (marker-position marker) (1+ position))))
          (set-marker marker nil))))))

(ert-deftest ebox-overlay-structural-updates-keep-the-surrounding-row-count ()
  "Overlay content growth, movement and resizing never shift the canvas's rows."
  (ebox-test-with-mounted
      (buffer root
              '(column :width (ch 40)
                       (box :height (lh 9) "Underlay")
                       (box "Bottom")
                       (box :id "overlay" :position absolute :layer root
                            :top (lh 1) :left (ch 3) :width (ch 24) :height (lh 6)
                            (column (text "Header") (text :id "subject" "Before")))))
    (let* ((subject (car (ebox-selector-query root "#subject")))
           (overlay (car (ebox-selector-query root "#overlay")))
           (rows (length (split-string (ebox-test-buffer-text buffer) "\n"))))
      (dolist (change (list (lambda () (ebox-node-set-text subject "First\nSecond\nThird"))
                           (lambda () (ebox-node-set-text subject "Short"))
                           (lambda () (ebox-node-put overlay :top '(lh 3)))
                           (lambda () (ebox-node-put overlay :height '(lh 4)))
                           (lambda () (ebox-node-put overlay :top '(lh -2)))
                           (lambda () (ebox-node-put subject :color "#A02030"))))
        (funcall change)
        (let* ((text (ebox-test-buffer-text buffer))
               (current-rows (length (split-string text "\n")))
               (matches (ebox-test-buffer-matches-render-p root buffer))
               (report (ebox-buffer-update-report buffer)))
          (should (= rows current-rows))
          (should matches)
          (should (string-match-p "Bottom" text))
          (dolist (range (plist-get report :ranges))
            (should (= (nth 1 range) (nth 2 range)))))))))

(ert-deftest ebox-overlay-local-publication-respects-nested-hosts-and-stacking ()
  "A root-layer descendant uses its host coordinates and keeps higher paint."
  (ebox-test-with-mounted
      (buffer root
              '(column :width (ch 40) :height (lh 14)
                       (box "Underlay")
                       (column :position absolute :layer root :top (lh 2)
                               :width (ch 30) :height (lh 9) :z-index 1
                               (box "Outer")
                               (column :id "inner" :position absolute :layer root
                                       :top (lh 5) :left (ch 3) :width (ch 24)
                                       :height (lh 4) :z-index 2
                                       (text :id "subject" "Before")
                                       (text "Covered")))
                       (box :position absolute :layer root :top (lh 6) :left (ch 3)
                            :width (ch 24) :height (lh 1) :z-index 3 "Higher")))
    (let ((subject (car (ebox-selector-query root "#subject")))
          (inner (car (ebox-selector-query root "#inner"))))
      (ebox-node-set-text subject "After!")
      (let ((report (ebox-buffer-update-report buffer))
            (matches (ebox-test-buffer-matches-render-p root buffer)))
        (should (= (plist-get report :lines) 1))
        (should matches))
      (let ((text (ebox-test-buffer-text buffer)))
        (should (string-match-p "After!" text))
        (should (string-match-p "Higher" text))
        (should-not (string-match-p "Covered" text)))
      (ebox-node-put inner :z-index 4)
      (let ((matches (ebox-test-buffer-matches-render-p root buffer))
            (text (ebox-test-buffer-text buffer)))
        (should matches)
        (should (string-match-p "Covered" text))
        (should-not (string-match-p "Higher" text))))))

;;; ebox-update-tests.el ends here
