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

(ert-deftest ebox-repaint-aligns-window-start-to-row-beginning ()
  "Repainting a scrolled buffer restores window start to column 0 of its row."
  (let ((buffer (get-buffer-create " *ebox-repaint-start-bol*"))
        (config (current-window-configuration)))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buffer)
          (let* ((window (selected-window))
                 (count (+ (window-body-height window) 20))
                 (rows (cl-loop for i below count
                                collect `(box ,(format "Row-%02d" i))))
                 (root (ebox-mount buffer `(column :padding-left (ch 2) ,@rows)))
                 (target (nth 10 (ebox-node-children root))))
            (with-current-buffer buffer
              (goto-char (point-min))
              (forward-line 10)
              (let ((bol (line-beginning-position)))
                ;; Place window-start past the left-padding cell on row 10.
                (set-window-start window (1+ bol) t)
                (ebox-node-set-text (car (ebox-node-children target)) "Row-10-updated")
                (let* ((ws (window-start window))
                       (ws-bol (save-excursion (goto-char ws) (line-beginning-position))))
                  (should (= ws ws-bol))
                  (should (= (line-number-at-pos ws) 11)))))))
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

(ert-deftest ebox-touching-structural-edits-coalesce-into-lines-strategy ()
  "Replacing, inserting or deleting adjacent stacked children uses `lines' strategy."
  (let* ((items (cl-loop for i below 40
                         collect `(box :id ,(format "b%d" i) ,(format "Block-%02d" i)))))
    (ebox-test-with-mounted (buffer root `(column :width (ch 40) ,@items))
      (let ((b2 (car (ebox-selector-query root "#b2")))
            (b3 (car (ebox-selector-query root "#b3"))))
        ;; Replace 1-line child with a 3-line child in one batch (remove + insert at same y).
        (ebox-with-batch
          (ebox-node-remove b2)
          (ebox-node-insert root (ebox-build '(column :id "rep" (box "R1") (box "R2") (box "R3"))) 2))
        (let ((report (ebox-buffer-update-report buffer))
              (matches (ebox-test-buffer-matches-render-p root buffer)))
          (should (eq (plist-get report :strategy) 'lines))
          (should (= (plist-get report :edits) 1))
          (should (<= (plist-get report :lines) 4))
          (should matches))
        ;; Insert two consecutive siblings in one batch.
        (ebox-with-batch
          (ebox-node-insert root (ebox-build '(box :id "ins1" "Ins-1")) 3)
          (ebox-node-insert root (ebox-build '(box :id "ins2" "Ins-2")) 4))
        (let ((report (ebox-buffer-update-report buffer))
              (matches (ebox-test-buffer-matches-render-p root buffer)))
          (should (eq (plist-get report :strategy) 'lines))
          (should (= (plist-get report :edits) 1))
          (should (<= (plist-get report :lines) 4))
          (should matches))
        ;; Delete two consecutive siblings in one batch.
        (let ((ins1 (car (ebox-selector-query root "#ins1")))
              (ins2 (car (ebox-selector-query root "#ins2"))))
          (ebox-with-batch
            (ebox-node-remove ins1)
            (ebox-node-remove ins2)
            (ebox-node-remove b3))
          (let ((report (ebox-buffer-update-report buffer))
                (matches (ebox-test-buffer-matches-render-p root buffer)))
            (should (eq (plist-get report :strategy) 'lines))
            (should (= (plist-get report :edits) 1))
            (should matches)))))))

(ert-deftest ebox-disjoint-height-changing-edits-stay-on-lines-strategy ()
  "Multiple disjoint height-changing edits and bordered growth stay on `lines' strategy."
  (let* ((middle (cl-loop for i below 25
                          collect `(box :id ,(format "m%d" i) ,(format "Mid-%02d" i))))
         (bordered-rows (cl-loop for i below 15
                                 collect `(box :id ,(format "c%d" i) ,(format "Code-%02d" i)))))
    (ebox-test-with-mounted
        (buffer root
                `(column :width (ch 40)
                         (box :id "head" "Head")
                         (column :id "card" :border ((px 1) solid "#888888")
                                 ,@bordered-rows)
                         ,@middle
                         (box :id "tail" "Tail")))
      (let ((head (car (ebox-selector-query root "#head")))
            (c7 (car (ebox-selector-query root "#c7")))
            (m20 (car (ebox-selector-query root "#m20")))
            (tail (car (ebox-selector-query root "#tail"))))
        ;; Growing a row inside a bordered container also touches its border lines.
        (ebox-node-set-text (car (ebox-node-children c7)) "Code-07-A\nCode-07-B\nCode-07-C")
        (let ((report (ebox-buffer-update-report buffer))
              (matches (ebox-test-buffer-matches-render-p root buffer)))
          (should (eq (plist-get report :strategy) 'lines))
          (should (< (plist-get report :lines) 15))
          (should matches))
        ;; Simultaneous growth near top and shrink + insert far below in one batch.
        (ebox-with-batch
          (ebox-node-set-text (car (ebox-node-children head)) "Head-1\nHead-2\nHead-3")
          (ebox-node-set-text (car (ebox-node-children c7)) "Code-07-short")
          (ebox-node-set-text (car (ebox-node-children m20)) "Mid-20-A\nMid-20-B")
          (ebox-node-insert root (ebox-build '(box :id "extra" "Extra-line")) 30)
          (ebox-node-set-text (car (ebox-node-children tail)) "Tail-updated"))
        (let ((report (ebox-buffer-update-report buffer))
              (matches (ebox-test-buffer-matches-render-p root buffer)))
          (should (eq (plist-get report :strategy) 'lines))
          (should (< (plist-get report :lines) 20))
          (should matches))))))

(ert-deftest ebox-same-column-insert-and-sibling-growth-match-fresh-render ()
  "Combining structural insert/remove and sibling height change in one column renders accurately."
  (let* ((items (cl-loop for i below 20
                         collect `(box :id ,(format "r%d" i) ,(format "Row-%02d" i)))))
    (ebox-test-with-mounted (buffer root `(column :width (ch 40) ,@items))
      (let ((r2 (car (ebox-selector-query root "#r2")))
            (r12 (car (ebox-selector-query root "#r12"))))
        ;; Insert later sibling AND grow earlier sibling in the same column batch.
        (ebox-with-batch
          (ebox-node-insert root (ebox-build '(box :id "added" "Added-1\nAdded-2")) 15)
          (ebox-node-set-text (car (ebox-node-children r2)) "Row-02-A\nRow-02-B\nRow-02-C"))
        (let ((report (ebox-buffer-update-report buffer))
              (matches (ebox-test-buffer-matches-render-p root buffer)))
          (should (eq (plist-get report :strategy) 'lines))
          (should matches))
        ;; Delete sibling immediately before a growing sibling in the same batch.
        (let ((r11 (car (ebox-selector-query root "#r11"))))
          (ebox-with-batch
            (ebox-node-remove r11)
            (ebox-node-set-text (car (ebox-node-children r12)) "Row-12-X\nRow-12-Y\nRow-12-Z"))
          (let ((report (ebox-buffer-update-report buffer))
                (matches (ebox-test-buffer-matches-render-p root buffer)))
            (should (eq (plist-get report :strategy) 'lines))
            (should matches)))))))

(ert-deftest ebox-side-by-side-column-cancelling-height-edits-keep-siblings-intact ()
  "Cancelling +1/-1 edits in one flex-row pane rewrite in place without shifting siblings."
  (ebox-test-with-mounted
      (buffer root
              '(flex :width (ch 72) :height (lh 12) :flex-direction row
                     (column :id "sidebar" :width (ch 20)
                             (box "S0") (box "S1") (box "S2") (box "S3")
                             (box "S4") (box "S5") (box "S6") (box "S7"))
                     (column :id "main" :width (ch 26)
                             (box "M0") (box "M1") (box "M2") (box "M3")
                             (box "M4") (box "M5") (box "M6") (box "M7"))
                     (column :id "rail" :width (ch 26)
                             (column :id "inspector"
                                     (box :id "i0" "I0")
                                     (box :id "i1" "I1")
                                     (box :id "i2" "I2")
                                     (box :id "i3" "I3")
                                     (box :id "i4" "I4-line1\nI4-line2")
                                     (box :id "i5" "I5")))))
    (let ((inspector (car (ebox-selector-query root "#inspector")))
          (i4 (car (ebox-selector-query root "#i4"))))
      (ebox-with-batch
        (ebox-node-insert inspector (ebox-build '(box :id "ix" "IX")) 1)
        (ebox-node-set-text (car (ebox-node-children i4)) "I4-short"))
      (let* ((report (ebox-buffer-update-report buffer))
             (strategy (plist-get report :strategy))
             (ranges (plist-get report :ranges))
             (same-height (cl-every (lambda (r) (= (nth 1 r) (nth 2 r))) ranges))
             (matches (ebox-test-buffer-matches-render-p root buffer)))
        (should (eq strategy 'lines))
        (should same-height)
        (should matches)))))

(ert-deftest ebox-overlay-and-bordered-stack-stay-consistent-under-cancelling-edits ()
  "Cancelling edits keep root overlays anchored and bordered-stack edges accurate."
  ;; Root overlay stays anchored when a nested column has cancelling +1/-1 edits.
  (ebox-test-with-mounted
      (buffer root
              '(column :width (ch 40)
                       (column :id "inner"
                               (box :id "a0" "A0")
                               (box :id "a1" "A1")
                               (box :id "a2" "A2")
                               (box :id "a3" "A3")
                               (box :id "a4" "A4")
                               (box :id "a5" "A5-1\nA5-2")
                               (box :id "a6" "A6"))
                       (box :id "ov" :position absolute :layer root
                            :top (lh 2) :left (ch 5) :width (ch 15) :height (lh 2)
                            "OVERLAY")))
    (let ((inner (car (ebox-selector-query root "#inner")))
          (a5 (car (ebox-selector-query root "#a5"))))
      (ebox-with-batch
        (ebox-node-insert inner (ebox-build '(box :id "ax" "AX")) 1)
        (ebox-node-set-text (car (ebox-node-children a5)) "A5-short"))
      (let ((matches (ebox-test-buffer-matches-render-p root buffer)))
        (should matches))))
  ;; Bordered stack (direct and nested) keeps top/bottom border faces on exact edge lines.
  (dolist (nested '(nil t))
    (ebox-test-with-mounted
        (buffer root
                (if nested
                    '(column :width (ch 40)
                             (column :id "card" :border ((px 1) solid "#888888")
                                     (column :id "host"
                                             (box :id "c0" "C0")
                                             (box :id "c1" "C1")
                                             (box :id "c2" "C2")
                                             (box :id "c3" "C3")
                                             (box :id "c4" "C4"))))
                  '(column :width (ch 40)
                           (column :id "host" :border ((px 1) solid "#888888")
                                   (box :id "c0" "C0")
                                   (box :id "c1" "C1")
                                   (box :id "c2" "C2")
                                   (box :id "c3" "C3")
                                   (box :id "c4" "C4")))))
      (let ((host (car (ebox-selector-query root "#host")))
            (c4 (car (ebox-selector-query root "#c4"))))
        (ebox-with-batch
          (ebox-node-insert host (ebox-build '(box :id "cnew" "CNEW")) 0)
          (ebox-node-remove c4))
        (let* ((matches (ebox-test-buffer-matches-render-p root buffer))
               (buf-lines (split-string (with-current-buffer buffer (buffer-string)) "\n"))
               (ref-lines (split-string (ebox-render root) "\n"))
               (props-match
                (and (= (length buf-lines) (length ref-lines))
                     (cl-every #'equal-including-properties buf-lines ref-lines))))
          (should matches)
          (should props-match))
        (ebox-with-batch
          (ebox-node-insert host (ebox-build '(box :id "cnew2" "CNEW2")) 0)
          (ebox-node-insert host (ebox-build '(box :id "cmid" "CMID")) 3))
        (let* ((matches (ebox-test-buffer-matches-render-p root buffer))
               (buf-lines (split-string (with-current-buffer buffer (buffer-string)) "\n"))
               (ref-lines (split-string (ebox-render root) "\n"))
               (props-match
                (and (= (length buf-lines) (length ref-lines))
                     (cl-every #'equal-including-properties buf-lines ref-lines))))
          (should matches)
          (should props-match))))))

(ert-deftest ebox-reparent-child-from-removed-wrapper-into-emptied-column ()
  "Unwrapping a laid-out child from a removed wrapper into an emptied column renders cleanly."
  (ebox-test-with-mounted
      (buffer root '(column :width (ch 40)
                            (column :id "outer"
                                    (column :id "wrap"
                                            (box :id "inner" "Body line")
                                            (box :id "comp" "Companion")))))
    (let ((outer (car (ebox-selector-query root "#outer")))
          (wrap (car (ebox-selector-query root "#wrap")))
          (inner (car (ebox-selector-query root "#inner"))))
      (ebox-with-batch
        (ebox-node-remove inner)
        (ebox-node-remove wrap)
        (ebox-node-insert outer inner 0))
      (let ((matches (ebox-test-buffer-matches-render-p root buffer)))
        (should matches)))))

(ert-deftest ebox-bordered-accordion-collapse-and-switch-stay-on-lines-strategy ()
  "Collapsing or switching sections in a bordered stack uses incremental `lines' edits."
  (let* ((padding (cl-loop for i below 60
                           collect `(box :id ,(format "p%d" i) ,(format "Pad-%02d" i)))))
    (ebox-test-with-mounted
        (buffer root
                `(column :width (ch 40)
                         ,@padding
                         (column :id "acc" :border ((px 1) solid "#888888")
                                 (box :id "h0" :border-bottom ((px 1) solid "#888888")
                                      (text :id "t0" "v First"))
                                 (box :id "b0" :border-bottom ((px 1) solid "#888888")
                                      (column "B0-1" "B0-2" "B0-3"))
                                 (box :id "h1"
                                      (text :id "t1" "> Second")))
                         (box "After")))
      (let ((acc (car (ebox-selector-query root "#acc")))
            (t0 (car (ebox-selector-query root "#t0")))
            (t1 (car (ebox-selector-query root "#t1")))
            (b0 (car (ebox-selector-query root "#b0")))
            (h1 (car (ebox-selector-query root "#h1"))))
        ;; 1. Collapse open section (update header + remove body in one batch).
        (ebox-with-batch
          (ebox-node-set-text t0 "> First")
          (ebox-node-remove b0))
        (let* ((report (ebox-buffer-update-report buffer))
               (buf-lines (split-string (with-current-buffer buffer (buffer-string)) "\n"))
               (ref-lines (split-string (ebox-render root) "\n")))
          (should (eq (plist-get report :strategy) 'lines))
          (should (< (plist-get report :lines) 10))
          (should (ebox-test-buffer-matches-render-p root buffer))
          (should (cl-every #'equal-including-properties buf-lines ref-lines)))
        ;; 2. Expand second section (update last header + insert body at end).
        (let ((b1 (ebox-build '(box :id "b1" (column "B1-1" "B1-2" "B1-3")))))
          (ebox-with-batch
            (ebox-node-set-text t1 "v Second")
            (ebox-node-put h1 :border-bottom '((px 1) solid "#888888"))
            (ebox-node-insert acc b1 2))
          (let* ((report (ebox-buffer-update-report buffer))
                 (buf-lines (split-string (with-current-buffer buffer (buffer-string)) "\n"))
                 (ref-lines (split-string (ebox-render root) "\n")))
            (should (eq (plist-get report :strategy) 'lines))
            (should (< (plist-get report :lines) 10))
            (should (ebox-test-buffer-matches-render-p root buffer))
            (should (cl-every #'equal-including-properties buf-lines ref-lines)))
          ;; 3. Switch back to first section (insert b0 + remove b1 + update both headers).
          (let ((b0-new (ebox-build '(box :id "b0n" :border-bottom ((px 1) solid "#888888")
                                          (column "B0-1" "B0-2" "B0-3")))))
            (ebox-with-batch
              (ebox-node-set-text t0 "v First")
              (ebox-node-insert acc b0-new 1)
              (ebox-node-set-text t1 "> Second")
              (ebox-node-set-props h1 '(:id "h1"))
              (ebox-node-remove b1))
            (let* ((report (ebox-buffer-update-report buffer))
                   (buf-lines (split-string (with-current-buffer buffer (buffer-string)) "\n"))
                   (ref-lines (split-string (ebox-render root) "\n")))
              (should (eq (plist-get report :strategy) 'lines))
              (should (< (plist-get report :lines) 12))
              (should (ebox-test-buffer-matches-render-p root buffer))
              (should (cl-every #'equal-including-properties buf-lines ref-lines)))))))))

(ert-deftest ebox-viewport-prepare-hook-batches-mutations-into-one-flush ()
  "Mutations applied during `ebox-viewport-prepare-functions' share the refit flush."
  (ebox-test-with-mounted (buffer root '(column :width (vw 100)
                                                (box :id "label" "initial")))
    (let* ((label (car (ebox-selector-query root "#label")))
           (settled nil)
           (before (ebox-mount-flush-count buffer))
           (prepare-hook
            (lambda (changed)
              (when (eq changed buffer)
                (ebox-node-set-text (ebox-node-child label 0)
                                    (format "w=%d" (car (ebox-mount-viewport changed)))))))
           (change-hook
            (lambda (changed)
              (when (eq changed buffer)
                (push (list (ebox-mount-viewport changed)
                            (plist-get (ebox-node-geometry root) :width)
                            (string-trim (ebox-test-buffer-text changed)))
                      settled)))))
      (add-hook 'ebox-viewport-prepare-functions prepare-hook)
      (add-hook 'ebox-viewport-change-functions change-hook)
      (unwind-protect
          (progn
            (ebox-mount-set-viewport buffer 30 10)
            (should (= (ebox-mount-flush-count buffer) (1+ before)))
            (should (equal settled (list (list '(30 . 10) 30 "w=30"))))
            (let ((ebox-viewport-width 30) (ebox-viewport-height 10))
              (should (ebox-test-buffer-matches-render-p root buffer))))
        (remove-hook 'ebox-viewport-prepare-functions prepare-hook)
        (remove-hook 'ebox-viewport-change-functions change-hook)))))

(ert-deftest ebox-bulk-line-reflow-matches-render-and-preserves-positions ()
  "Large width reflows taking the bulk buffer rewrite stay identical to `ebox-render'."
  (let* ((rows (cl-loop for i from 1 to 160
                        collect (list 'box :width 'stretch
                                      (format "Row %03d alpha beta gamma delta epsilon" i))))
         (tree (cons 'column (cons :width (cons '(vw 100) rows)))))
    (ebox-test-with-mounted (buffer root tree)
      (ebox-mount-set-viewport buffer 60 20)
      (let ((ebox-viewport-width 60) (ebox-viewport-height 20))
        (should (ebox-test-buffer-matches-render-p root buffer)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line 40))
      (let ((before (ebox-mount-flush-count buffer)))
        (ebox-mount-set-viewport buffer 24 20)
        (should (= (ebox-mount-flush-count buffer) (1+ before)))
        (let ((ebox-viewport-width 24) (ebox-viewport-height 20))
          (should (ebox-test-buffer-matches-render-p root buffer)))
        (ebox-mount-set-viewport buffer 56 20)
        (should (= (ebox-mount-flush-count buffer) (+ 2 before)))
        (let ((ebox-viewport-width 56) (ebox-viewport-height 20))
          (should (ebox-test-buffer-matches-render-p root buffer)))))))

;;; ebox-update-tests.el ends here
