;;; etaf-keys-tests.el --- Scoped keys, dismissal, keyboard drag and palette -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(defun etaf-keys-test-press (key)
  "Run the command KEY is bound to in the current buffer, or signal."
  (let ((command (key-binding (kbd key) t)))
    (unless (commandp command) (error "Key %s runs %S" key command))
    (call-interactively command)
    command))

(ert-deftest etaf-keys-return-uses-live-focus-instead-of-displaced-point ()
  "Return and explicit activation follow live focus across local boundaries."
  (let ((inside 0) (outside 0) (host 0))
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column :keys (list (list "RET" (lambda () (cl-incf host)) "Host entry"))
            (box :ref 'outside :on-press (lambda () (cl-incf outside)) "Outside")
            (column :key-scope 'local
              (box :ref 'inside :tab-index 0
                   :on-press (lambda () (cl-incf inside)) "Inside")))))
      (etaf-focus runtime 'inside)
      (dolist (key '(nil "RET" "<return>"))
        (goto-char (etaf-host-ref-position runtime 'outside))
        (if key (etaf-keys-test-press key) (etaf-activate runtime))
        (should (eq (etaf-focused-host-ref runtime) 'inside)))
      (should (= inside 3))
      (should (= outside 0))
      (should (= host 0)))))

(ert-deftest etaf-keys-help-lists-effective-bindings ()
  "`?' keeps read-only key help inside the application's window and buffer."
  (etaf-test-with-mount (runtime (etaf-view
                                  (column :height '(lh 40)
                                          :keys (list (list "r" (lambda () (interactive)) "Reload"))
                                          (box :ref 'save :tab-index 0 :aria-label "Save file" "S")
                                          (box :ref 'plain :tab-index 0 "Plain control"))))
    (let ((buffers (buffer-list)) (windows (window-list))
          (before (buffer-substring-no-properties (point-min) (point-max))))
      (should (eq (key-binding (kbd "?") t) 'etaf-help))
      (etaf-focus runtime 'save)
      (let ((shown (etaf-help runtime))
            (data (etaf-help-data runtime))
            (text (buffer-substring-no-properties (point-min) (point-max))))
        (should (eq shown (current-buffer)))
        (should (equal buffers (buffer-list)))
        (should (equal windows (window-list)))
        (should (string-match-p "Reload" text))
        (should (string-match-p "M-g" text))
        (should (equal (plist-get data :controls) '("Save file" "Plain control"))))
      (etaf-help-close runtime)
      (should (eq (etaf-focused-host-ref runtime) 'save))
      (should (equal before (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest etaf-keys-resolve-from-focus-outward-and-nearest-wins ()
  "A Host's :keys work inside it; the nearest Host binding a key wins."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :ref 'app
                                            :keys (list (list "n" (lambda () (push 'app-n log)) "Next")
                                                        (list "x" (lambda () (push 'app-x log)) "Delete"))
                                            (box :ref 'first :tab-index 0 "first")
                                            (column :ref 'pane
                                                    :keys (list (list "n" (lambda () (push 'pane-n log))))
                                                    (box :ref 'second :tab-index 0 "second")))))
      (etaf-focus runtime 'first)
      (etaf-keys-test-press "n")
      (etaf-keys-test-press "x")
      (etaf-focus runtime 'second)
      (etaf-keys-test-press "n")
      (etaf-keys-test-press "x")
      (should (equal (nreverse log) '(app-n app-x pane-n app-x))))))

(ert-deftest etaf-keys-follow-point-moved-out-of-the-focus ()
  "Point moved into another Host by a command selects that Host's keys."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (row
                                     (column :ref 'list
                                             :keys (list (list "n" (lambda () (push 'list-n log))))
                                             (box :ref 'row :tab-index 0 "row"))
                                     (column :ref 'chat
                                             :keys (list (list "n" (lambda () (push 'chat-n log))))
                                             (box :ref 'message "message")))))
      (etaf-focus runtime 'row)
      (etaf-keys-test-press "n")
      (goto-char (etaf-host-ref-position runtime 'message))
      (etaf-keys-test-press "n")
      (should (equal (nreverse log) '(list-n chat-n))))))

(ert-deftest etaf-keys-sequences-are-scoped-and-share-prefixes ()
  "A prefix sequence works inside its Host and falls back to the buffer's map."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column (box :ref 'inside :tab-index 0
                                                 :keys (list (list "C-c C-u" (lambda () (push 'host log))))
                                                 "inside")
                                            (box :ref 'outside :tab-index 0 "outside"))))
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "C-c C-u") (lambda () (interactive) (push 'buffer-u log)))
        (define-key map (kbd "C-c C-k") (lambda () (interactive) (push 'buffer-k log)))
        (use-local-map map))
      (etaf-focus runtime 'inside)
      (etaf-keys-test-press "C-c C-u")
      (etaf-keys-test-press "C-c C-k")
      (etaf-focus runtime 'outside)
      (etaf-keys-test-press "C-c C-u")
      (should (equal (nreverse log) '(host buffer-k buffer-u))))))

(ert-deftest etaf-keys-commands-act-on-hosts-they-reveal ()
  "A key command sees its own writes published, like a keymap command."
  (let ((open (etaf-ref nil)) found)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :keys (list (list "o" (lambda ()
                                                                    (etaf-set-value open t)
                                                                    (setq found (etaf-host-ref-position
                                                                                 runtime 'field))
                                                                    (etaf-focus runtime 'field))))
                                            (box :ref 'start :tab-index 0 "start")
                                            (box :if (etaf-value open)
                                                 :ref 'field :tab-index 0 "field"))))
      (etaf-focus runtime 'start)
      (etaf-keys-test-press "o")
      (should found)
      (should (eq (etaf-focused-host-ref runtime) 'field)))))

(ert-deftest etaf-keys-focus-leave-precedes-entry-and-excludes-shared-ancestors ()
  "Focus observers leave inner-to-outer, then enter; a shared parent stays put."
  (let (log)
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column
           (box :ref 'outside :tab-index 0
                :on-focus-enter (lambda () (push 'enter-outside log)) "outside")
           (column :ref 'group
                   :on-focus-enter (lambda () (push 'enter-group log))
                   :on-focus-leave (lambda () (push 'leave-group log))
                   (box :ref 'a :tab-index 0
                        :on-focus-leave
                        (lambda ()
                          (push (list 'leave-a (etaf-focused-host-ref)) log)) "a")
                   (box :ref 'b :tab-index 0
                        :on-focus-enter (lambda () (push 'enter-b log))
                        :on-focus-leave (lambda () (push 'leave-b log)) "b")))))
      (etaf-focus runtime 'a)
      (etaf-focus-next runtime)
      (etaf-focus runtime 'b)
      (etaf-focus runtime 'outside)
      (should (equal (nreverse log)
                     '(enter-group (leave-a b) enter-b leave-b leave-group enter-outside))))))

(ert-deftest etaf-keys-focus-leave-redirection-stops-stale-entry ()
  "A leave handler may redirect focus without entering the superseded target."
  (let (log)
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column
           (box :ref 'a :tab-index 0
                :on-focus-leave (lambda () (etaf-focus nil 'outside)) "a")
           (box :ref 'b :tab-index 0
                :on-focus-enter (lambda () (push 'b log)) "b")
           (box :ref 'outside :tab-index 0
                :on-focus-enter (lambda () (push 'outside log)) "outside"))))
      (etaf-focus runtime 'a)
      (etaf-focus runtime 'b)
      (let ((focus (etaf-focused-host-ref runtime)))
        (should (eq focus 'outside)))
      (should (equal log '(outside))))))

(ert-deftest etaf-keys-focus-enter-runs-when-focus-moves-into-a-host ()
  "`:on-focus-enter' runs on each Host focus enters, not on moves inside it."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (box :ref 'outside :tab-index 0 "outside")
                                     (column :ref 'window
                                             :on-focus-enter (lambda () (push 'window log))
                                             (box :ref 'a :tab-index 0 "a")
                                             (box :ref 'b :tab-index 0
                                                  :on-focus-enter (lambda () (push 'b log))
                                                  "b")))))
      (etaf-focus runtime 'outside)
      (etaf-focus-next runtime)
      (etaf-focus-next runtime)
      (etaf-focus runtime 'outside)
      (etaf-focus runtime 'b)
      (should (equal (nreverse log) '(window b b window))))))

(ert-deftest etaf-keys-modal-scope-hides-outer-keys-and-escape-dismisses ()
  "An open modal Host confines keys, ignores stray letters; Escape dismisses, C-g stays native."
  (let ((open (etaf-ref t)) (log nil))
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :keys (list (list "q" (lambda () (push 'quit log))))
                                            (box :ref 'outside :tab-index 0 "outside")
                                            (column :if (etaf-value open)
                                                    :ref 'dialog :focus-scope 'modal
                                                    :on-dismiss (lambda ()
                                                                  (push 'dismiss log)
                                                                  (etaf-set-value open nil))
                                                    (box :ref 'ok :tab-index 0 "ok")))))
      (etaf-focus runtime 'outside)
      (should (eq (key-binding "q" t) #'ignore))
      (should (eq (key-binding "w" t) #'ignore))
      (etaf-keys-test-press "<escape>")
      (should (equal log '(dismiss)))
      (etaf-focus runtime 'outside)
      (etaf-keys-test-press "q")
      (should (equal log '(quit dismiss)))
      (should-not (eq (key-binding "w" t) #'ignore))
      (etaf-set-value open t)
      (etaf-focus runtime 'ok)
      (should (eq (key-binding (kbd "C-g") t) 'keyboard-quit))
      (should (equal log '(quit dismiss)))
      (should (etaf-value open)))))

(ert-deftest etaf-keys-behaviors-move-and-resize-from-the-keyboard ()
  "Draggable and resizable Behaviors accept M-arrows and M-S-arrows."
  (let* ((x (etaf-ref 10)) (y (etaf-ref 5))
         (width (etaf-ref 20)) (height (etaf-ref 4))
         (move (etaf-draggable :x x :y y))
         (resize (etaf-resizable :width width :height height
                                 :min-width 19)))
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (box :ref 'title :tab-index 0 :use (list move) "title")
                                     (box :ref 'grip :tab-index 0 :use (list resize) "grip"))))
      (etaf-focus runtime 'title)
      (etaf-keys-test-press "M-<right>")
      (etaf-keys-test-press "M-<down>")
      (should (equal (list (etaf-value x) (etaf-value y))
                     (list (+ 10 (frame-char-width)) (+ 5 (frame-char-height)))))
      (should-not (key-binding (kbd "M-S-<right>") t))
      (etaf-focus runtime 'grip)
      (etaf-keys-test-press "M-S-<right>")
      (should (= (etaf-value width) (+ 20 (frame-char-width))))
      (etaf-keys-test-press "M-S-<left>")
      (etaf-keys-test-press "M-S-<left>")
      (should (= (etaf-value width) 19))
      (etaf-keys-test-press "M-S-<up>")
      (should (= (etaf-value height) (- 4 (frame-char-height)))))))

(ert-deftest etaf-keys-drag-step-and-arrows-step-a-focused-separator ()
  "`etaf-drag-step' drives :on-drag; arrows step a focused separator."
  (let (gestures)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column
                                     (box :ref 'above :tab-index 0 "above")
                                     (box :ref 'split :tab-index 0 :role 'separator
                                          :aria-orientation 'vertical
                                          :on-drag (lambda (gesture) (push gesture gestures))
                                          "|"))))
      (should (eq (etaf-drag-step runtime 'split 2 0) 'split))
      (should (equal (mapcar (lambda (g) (plist-get g :phase)) gestures) '(end start)))
      (should (equal (plist-get (car gestures) :delta) (cons (* 2 (frame-char-width)) 0)))
      (should (plist-get (car gestures) :keyboard))
      (setq gestures nil)
      (etaf-focus runtime 'split)
      (etaf-keys-test-press "<left>")
      (should (equal (plist-get (car gestures) :delta) (cons (- (frame-char-width)) 0)))
      (setq gestures nil)
      (etaf-keys-test-press "<up>")
      (should-not gestures)
      (should (equal (etaf-focused-host-ref runtime) 'above)))))

(ert-deftest etaf-keys-palette-lists-labelled-keys-and-controls ()
  "The palette runs labelled keys and presses controls; `?' opens help instead."
  (let (log offered)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :keys (list (list "r" (lambda () (push 'reload log)) "Reload")
                                                        (list "z" (lambda () (push 'hidden log))))
                                            (box :ref 'save :tab-index 0
                                                 :on-press (lambda () (push 'save log))
                                                 "Save file")
                                            (box :ref 'gear :tab-index 0 :aria-label "Settings"
                                                 :on-press (lambda () (push 'settings log))
                                                 "*"))))
      (etaf-focus runtime 'save)
      (should (eq (key-binding (kbd "?") t) 'etaf-help))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   (car (member "Settings" offered)))))
        (etaf-palette runtime))
      (should (equal offered '("Reload" "Save file" "Settings")))
      (should (equal log '(settings)))
      (should (equal (etaf-focused-host-ref runtime) 'gear))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) "Reload")))
        (etaf-palette runtime))
      (should (equal log '(reload settings)))
      (let ((map (make-sparse-keymap)))
        (define-key map "?" #'describe-mode)
        (use-local-map map))
      ;; `?' is framework-reserved: a buffer keymap cannot shadow the help.
      (should (eq (key-binding (kbd "?") t) 'etaf-help)))))

(ert-deftest etaf-keys-direction-handler-handles-hold-and-release ()
  "`:on-direction' results control whether the key falls through."
  (let (log)
    (etaf-test-with-mount (runtime (etaf-view
                                    (column :ref 'app
                                            :on-direction
                                            (lambda (direction)
                                              (push direction log)
                                              (if (eq direction 'up) 'handled 'release))
                                            (box :ref 'first :tab-index 0 "1")
                                            (box :ref 'second :tab-index 0 "2"))))
      (etaf-focus runtime 'first)
      (etaf-keys-test-press "<up>")
      (should (equal log '(up)))
      (should (eq (etaf-focused-host-ref runtime) 'first))
      (etaf-keys-test-press "<down>")
      (should (equal log '(down up)))
      (should (eq (etaf-focused-host-ref runtime) 'second)))))

(ert-deftest etaf-keys-drag-step-measures-the-canvas-face ()
  "A keyboard drag step travels canvas cells, not the frame's own face.
A canvas font or a text scale is a different cell from the frame's default,
and a step measured with the frame's one moves the separator the wrong
distance."
  (let (gestures)
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column
           (box :ref 'split :tab-index 0
                :on-drag (lambda (gesture) (push gesture gestures))
                "|"))))
      (cl-letf (((symbol-function 'ebox-display-metrics)
                 (lambda (&optional _buffer)
                   (list :char-width 10 :line-height 18 :ascent 100)))
                ((symbol-function 'frame-char-width) (lambda (&optional _frame) 20))
                ((symbol-function 'frame-char-height) (lambda (&optional _frame) 40)))
        (etaf-drag-step runtime 'split 3 2)
        (should (equal (plist-get (car gestures) :delta) (cons 30 36)))))))

(ert-deftest etaf-keys-arrows-cross-regions-at-their-boundary ()
  "Arrow movement stays inside a region and enters the adjacent one at its edge."
  (etaf-test-with-mount (runtime (etaf-view
                                  (column
                                   (column :region '(:id list :key "l")
                                           (box :ref 'a :tab-index 0 "A")
                                           (box :ref 'b :tab-index 0 "B"))
                                   (column :region '(:id detail :key "d")
                                           (box :ref 'detail :tab-index 0 "D")))))
    (etaf-focus runtime 'a)
    (etaf-keys-test-press "<down>")
    (should (eq (etaf-focused-host-ref runtime) 'b))
    (etaf-keys-test-press "<down>")
    (should (eq (etaf-focused-host-ref runtime) 'detail))
    (etaf-keys-test-press "<up>")
    (should (eq (etaf-focused-host-ref runtime) 'b))))

(ert-deftest etaf-keys-tab-traverses-and-cycles-focus-stops ()
  "Tab and S-Tab walk the modal scope's stops in opposite order and wrap."
  (etaf-test-with-mount (runtime (etaf-view
                                  (column
                                   (box :ref 'one :tab-index 0 "1")
                                   (box :ref 'two :tab-index 0 "2"))))
    (etaf-focus runtime 'one)
    (etaf-keys-test-press "TAB")
    (should (eq (etaf-focused-host-ref runtime) 'two))
    (etaf-keys-test-press "TAB")
    (should (eq (etaf-focused-host-ref runtime) 'one))
    (etaf-keys-test-press "<backtab>")
    (should (eq (etaf-focused-host-ref runtime) 'two))))

(ert-deftest etaf-keys-vim-scheme-dispatches-and-rejects-conflicts ()
  "The Vim scheme dispatches HJKL and refuses conflicting runtimes."
  (etaf-test-with-mount (runtime (etaf-view
                                  (row (box :ref 'left :tab-index 0 "L")
                                       (box :ref 'right :tab-index 0 "R"))))
    (unwind-protect
        (progn
          (etaf-set-direction-scheme 'vim runtime)
          (etaf-focus runtime 'left)
          (etaf-keys-test-press "l")
          (should (eq (etaf-focused-host-ref runtime) 'right))
          (etaf-keys-test-press "h")
          (should (eq (etaf-focused-host-ref runtime) 'left)))
      (etaf-set-direction-scheme 'arrows runtime)))
  (etaf-test-with-mount (runtime (etaf-view
                                  (column :keys (list (list "l" (lambda () (interactive)) "Local"))
                                          (box :ref 'one :tab-index 0 "1"))))
    (setq etaf-direction-scheme 'arrows)
    (should-error (etaf-set-direction-scheme 'vim runtime) :type 'user-error)
    (should (eq etaf-direction-scheme 'arrows)))
  (etaf-test-with-mount (runtime (etaf-view
                                  (column :region '(:id hint :key "j")
                                          (box :ref 'one :tab-index 0 "1"))))
    (should-error (etaf-set-direction-scheme 'vim runtime) :type 'user-error)
    (should (eq etaf-direction-scheme 'arrows))))

(ert-deftest etaf-keys-vim-scheme-rejects-vim-letter-declarations ()
  "With Vim enabled, `:keys' and region hints using h/j/k/l are render errors."
  (let ((etaf-direction-scheme 'vim))
    (should-error (etaf-test-with-mount
                       (runtime (etaf-node 'box
                                           (list :keys (list (list "l" #'ignore)))
                                           (list "x")))
                     runtime)
                  :type 'etaf-renderer-error)
    (should-error (etaf-test-with-mount
                       (runtime (etaf-node 'box (list :region '(:id r :key "j"))
                                           (list "x")))
                     runtime)
                  :type 'etaf-renderer-error)))

(ert-deftest etaf-keys-reject-invalid-bindings ()
  "Malformed :keys, :focus-group and :focus-scope values are render errors."
  (dolist (props (list (list :keys '(("n")))
                       (list :keys (list (list "g g" #'ignore)))
                       (list :keys (list (list "M-g" #'ignore)))
                       (list :keys (list (list "?" #'ignore)))
                       (list :keys (list (list "TAB" #'ignore)))
                       (list :keys (list (list "<left>" #'ignore)))
                       (list :keys (list (list "C-c" #'ignore) (list "C-c n" #'ignore)))
                       (list :keys (list (list "n" #'ignore 'label)))
                       (list :focus-group 'diagonal)
                       (list :focus-scope 'global)))
    (should-error (etaf-test-with-mount (runtime (etaf-node 'box props (list "x")))
                    runtime)
                  :type 'etaf-renderer-error)))

(ert-deftest etaf-keys-keymap-reserved-events-scan ()
  "The public scanner reports reserved events and accepts clean keymaps."
  (let ((clean (let ((map (make-sparse-keymap)))
                 (define-key map (kbd "C-c C-j") #'ignore)
                 (define-key map (kbd "RET") #'ignore)
                 (define-key map (kbd "M-p") #'ignore)
                 map))
        (dirty (let ((map (make-sparse-keymap)))
                 (define-key map (kbd "TAB") #'ignore)
                 (define-key map (kbd "<left>") #'ignore)
                 (define-key map (kbd "C-g") #'ignore)
                 map)))
    (should-not (etaf-keymap-reserved-events nil))
    (should-not (etaf-keymap-reserved-events clean))
    (let ((found (etaf-keymap-reserved-events dirty)))
      (should (= (length found) 3))
      (should (member (vconcat (kbd "TAB")) found))
      (should (member (vconcat (kbd "<left>")) found))
      (should (member (vconcat (kbd "C-g")) found)))))


(ert-deftest etaf-keys-return-keeps-a-focused-control-before-an-enclosing-binding ()
  "RET activates the focused control rather than an enclosing Host's RET key."
  (let ((pressed 0) (opened 0))
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column
            (box :ref 'outside "Outside")
            (column :key-scope 'local
                    :keys (list (list "RET" (lambda () (cl-incf opened)) "Open"))
              (box :ref 'button :tab-index 0 :on-press (lambda () (cl-incf pressed))
                   "Button")
              (box :ref 'plain :tab-index 0 "Plain")))))
      ;; Focus answers inside a local scope even when point is elsewhere,
      ;; so the control's own keymap is not the one under point.
      (dolist (ref '(button plain))
        (etaf-focus runtime ref)
        (goto-char (etaf-host-ref-position runtime 'outside))
        (etaf-keys-test-press "RET"))
      (should (equal (list pressed opened) '(1 1))))))

(ert-deftest etaf-keys-pointer-events-resolve-from-the-host-under-the-pointer ()
  "A wheel event runs the binding of the Host under the pointer."
  (let (log)
    (etaf-test-with-mount
        (runtime
         (etaf-view
          (column :keys (list (list "<wheel-up>" (lambda () (push 'root log))))
            (box :ref 'pane
                 :keys (list (list "<wheel-up>" (lambda () (push 'pane log))))
                 "Pane")
            (box :ref 'other :tab-index 0 "Other"))))
      (set-window-buffer (selected-window) (current-buffer))
      (etaf-focus runtime 'other)
      (dolist (ref '(pane other))
        (let* ((position (etaf-host-ref-position runtime ref))
               (last-input-event
                (list 'wheel-up (list (selected-window) position '(0 . 0) 0))))
          (call-interactively (key-binding [wheel-up] t))))
      (should (equal (nreverse log) '(pane root))))))

(ert-deftest etaf-keys-resolve-to-named-symbols-and-leave-this-command-a-symbol ()
  "Key commands are named symbols, so printing one never prints a Runtime."
  (etaf-test-with-mount
      (runtime
       (etaf-view
        (column :ref 'root
                :keys (list (list "x" (lambda () (interactive)) "Run"))
                :on-dismiss (lambda () nil)
                (box :ref 'first :tab-index 0 "First")
                (box :ref 'second :tab-index 0 "Second"))))
    (etaf-focus runtime 'first)
    (dolist (key '("x" "TAB" "<down>" "<escape>"))
      (let ((command (key-binding (kbd key) t)))
        (should (symbolp command))
        (should (commandp command))
        (should (string-prefix-p "etaf-key-" (symbol-name command)))
        (should (< (length (format "%s" command)) 64))))
    (set-window-buffer (selected-window) (current-buffer))
    (let (seen)
      (let ((hook (lambda () (push this-command seen))))
        (add-hook 'post-command-hook hook nil t)
        (unwind-protect
            (execute-kbd-macro (kbd "TAB"))
          (remove-hook 'post-command-hook hook t)))
      (should (equal (and (car seen) (symbolp (car seen))
                          (symbol-name (car seen)))
                     "etaf-key-tab")))))

;;; etaf-keys-tests.el ends here
