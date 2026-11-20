;;; ebox-scroll-input-tests.el --- Ebox scroll and input tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-node-set-scroll-clamps-and-repaints-visible-lines ()
  (ebox-test-with-mounted (buffer root
                           '(box :id "scroller" :width (ch 4) :height (lh 2)
                                 :overflow scroll
                                 (column
                                  (text "A")
                                  (text "B")
                                  (text "C"))))
    (should (equal (ebox-test-buffer-text buffer) "A 
B "))
    (should (= (ebox-node-scroll-offset root) 0))
    (should (= (ebox-node-set-scroll root 1) 1))
    (should (equal (ebox-test-buffer-text buffer) "B 
C "))
    (should (= (ebox-node-set-scroll root 99) 1))
    (should (= (ebox-node-scroll-offset root) 1))
    (should (ebox-test-buffer-matches-render-p root buffer))))

(ert-deftest ebox-end-anchored-scroll-follows-growing-content-while-pinned ()
  (ebox-test-with-mounted (buffer root
                           '(box :width (ch 4) :height (lh 2)
                                 :overflow scroll :scroll-anchor end
                                 (column :id "log"
                                  (text "A")
                                  (text "B")
                                  (text "C"))))
    (let ((log (car (ebox-selector-query root "#log"))))
      (should (equal (ebox-test-buffer-text buffer) "B 
C "))
      (should (= (ebox-node-scroll-offset root) 1))
      (ebox-node-insert log (ebox-text-create "D"))
      (should (equal (ebox-test-buffer-text buffer) "C 
D "))
      (should (= (ebox-node-scroll-offset root) 2))
      (should (= (ebox-node-set-scroll root 0) 0))
      (ebox-node-insert log (ebox-text-create "E"))
      (should (equal (ebox-test-buffer-text buffer) "A 
B "))
      (should (= (ebox-node-set-scroll root 99) 3))
      (ebox-node-insert log (ebox-text-create "F"))
      (should (equal (ebox-test-buffer-text buffer) "E 
F "))
      (should (ebox-test-buffer-matches-render-p root buffer))
      (should-error (ebox-node-create 'box '(:scroll-anchor middle))))))

(ert-deftest ebox-scroll-offset-follows-content-that-shrinks-below-it ()
  (let ((ebox-scroll-step 1))
    (ebox-test-with-mounted (buffer root
                             '(column (text "Header")
                                      (box :id "scroller" :width (ch 4) :height (lh 2)
                                           :overflow scroll
                                           (column :id "list"
                                                   (text "A") (text "B") (text "C")
                                                   (text "D") (text "E")))))
      (let ((scroller (car (ebox-selector-query root "#scroller")))
            (list (car (ebox-selector-query root "#list"))))
        (should (= (ebox-node-set-scroll scroller 3) 3))
        (ebox-node-replace-children
         list (mapcar #'ebox-text-create '("A" "B" "C")))
        ;; The offset reported and scrolled from is the one shown.
        (should (= (ebox-node-scroll-offset scroller) 1))
        (should (equal (ebox-test-buffer-text buffer) "Header \nB  \nC  "))
        (save-window-excursion
          (switch-to-buffer buffer)
          (goto-char (point-min))
          (forward-line 1)
          (ebox-scroll-up)
          (should (= (window-start) (point-min))))
        (should (= (ebox-node-scroll-offset scroller) 0))
        (should (equal (ebox-test-buffer-text buffer) "Header \nA  \nB  "))
        (should (ebox-test-buffer-matches-render-p root buffer))))))

(ert-deftest ebox-scroll-into-view-moves-nested-scrollers-minimally ()
  (ebox-test-with-mounted (buffer root
                           '(box :width (ch 4) :height (lh 3) :overflow scroll
                                 (column
                                  (text "A")
                                  (box :id "inner" :height (lh 2) :overflow scroll
                                       (column (text :id "first" "1") (text "2")
                                               (text :id "deep" "3")))
                                  (text "B")
                                  (text :id "last" "C"))))
    (let ((inner (car (ebox-selector-query root "#inner")))
          (deep (car (ebox-selector-query root "#deep")))
          (last (car (ebox-selector-query root "#last"))))
      (should (eq (ebox-node-scroll-into-view last) last))
      (should (= (ebox-node-scroll-offset root) 2))
      (should (equal (ebox-test-buffer-text buffer) "2 
B 
C "))
      (ebox-node-scroll-into-view deep)
      (should (= (ebox-node-scroll-offset inner) 1))
      (should (= (ebox-node-scroll-offset root) 2))
      (should (equal (ebox-test-buffer-text buffer) "3 
B 
C "))
      (ebox-node-set-scroll root 0)
      (ebox-node-scroll-into-view deep)
      (should (= (ebox-node-scroll-offset root) 0))
      (ebox-node-set-scroll root 2)
      (ebox-node-scroll-into-view (car (ebox-selector-query root "#first")))
      (should (= (ebox-node-scroll-offset inner) 0))
      (should (= (ebox-node-scroll-offset root) 1))
      (should (equal (ebox-test-buffer-text buffer) "1 
2 
B "))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-horizontal-wheel-gesture-fires-one-swipe-on-the-nearest-handler ()
  (let* ((swipes nil)
         (ebox-swipe-distance 60)
         (ebox-swipe-quiet 0.05)
         (mouse-wheel-flip-direction nil))
    (ebox-test-with-mounted (buffer root
                             `(box :swipe ,(lambda (dir) (push (list 'outer dir) swipes))
                                   (column
                                    (text :id "plain" "row")
                                    (box :id "inner"
                                         :swipe ,(lambda (dir) (push (list 'inner dir) swipes))
                                         (text :id "nested" "tile")))))
      (switch-to-buffer buffer)
      (cl-flet ((wheel (type id dx)
                  (let* ((node (car (ebox-selector-query root (concat "#" id))))
                         (posn (list (selected-window) (ebox-node-position node)
                                     '(0 . 0) 0)))
                    (ebox-wheel-swipe (list type posn 1 1 (cons (float dx) 0.0)))))
                (pause () (sleep-for 0.1)))
        (pause)
        (wheel 'wheel-left "plain" 30)
        (should-not swipes)
        (wheel 'double-wheel-left "plain" 40)
        (should (equal swipes '((outer right))))
        ;; Momentum of the same gesture is absorbed.
        (wheel 'triple-wheel-left "plain" 200)
        (should (equal swipes '((outer right))))
        ;; Reversing direction right away starts the next swipe, so a
        ;; reader can swipe left and right in a row without stopping.
        (wheel 'wheel-right "nested" 80)
        (should (equal swipes '((inner left) (outer right))))
        (wheel 'wheel-left "plain" 80)
        (should (equal swipes '((outer right) (inner left) (outer right))))
        ;; A pause ends the gesture too; the nearest handler wins.
        (pause)
        (wheel 'wheel-right "nested" 80)
        (should (equal (car swipes) '(inner left)))
        (let ((mouse-wheel-flip-direction t))
          (pause)
          (wheel 'wheel-right "plain" 80))
        (should (equal (car swipes) '(outer right)))
        (should-error (ebox-node-create 'box '(:swipe 3)) :type 'ebox-error)))))

(ert-deftest ebox-scroll-property-reports-changed-offsets ()
  (let ((offsets nil))
    (ebox-test-with-mounted (buffer root
                             `(box :id "scroller" :width (ch 4) :height (lh 2)
                                   :overflow scroll :scroll-anchor end
                                   :scroll ,(lambda (offset) (push offset offsets))
                                   (column :id "rows"
                                           (text "A") (text "B") (text "C"))))
      (should-not offsets)
      (goto-char (point-min))
      (ebox-scroll-up)
      (should (equal offsets '(0)))
      ;; An unchanged offset is not reported.
      (ebox-node-set-scroll root 0)
      (should (equal offsets '(0)))
      (ebox-node-set-scroll root 9)
      (should (equal offsets '(1 0)))
      ;; Growth that keeps a pinned scroller at its end is not a scroll.
      (ebox-node-insert (car (ebox-selector-query root "#rows"))
                        (ebox-text-create "D"))
      (should (equal (ebox-test-buffer-text buffer) "C 
D "))
      (should (equal offsets '(1 0)))
      (should-error (ebox-node-create 'box '(:scroll 3)) :type 'ebox-error))))

(ert-deftest ebox-scroll-commands-use-node-at-point ()
  (let ((ebox-scroll-step 1))
    (ebox-test-with-mounted (buffer root
                             '(box :id "scroller" :width (ch 4) :height (lh 2)
                                   :overflow scroll
                                   (column
                                    (text "A")
                                    (text "B")
                                    (text "C"))))
      (goto-char (point-min))
      (ebox-scroll-down)
      (should (equal (ebox-test-buffer-text buffer) "B 
C "))
      (ebox-scroll-up)
      (should (equal (ebox-test-buffer-text buffer) "A 
B ")))))

(ert-deftest ebox-scroll-past-the-end-keeps-a-fitting-buffer-in-place ()
  (let ((ebox-scroll-step 1))
    (ebox-test-with-mounted (buffer root
                             '(column (text "Header")
                                      (box :id "scroller" :width (ch 4) :height (lh 2)
                                           :overflow scroll
                                           (column (text "A") (text "B") (text "C")))))
      (save-window-excursion
        (switch-to-buffer buffer)
        (goto-char (point-min))
        (forward-line 1)
        (dotimes (_ 4) (ebox-scroll-down))
        (should (= (window-start) (point-min)))
        (should (equal (ebox-test-buffer-text buffer) "Header 
B  
C  "))))))

(ert-deftest ebox-wheel-over-chrome-keeps-a-fitting-canvas-in-place ()
  "A wheel turn that no scroll region consumes never slides a fitting tree.
A mounted canvas is the whole picture: once it fits the window, scrolling
the window would move every region at once instead of revealing content."
  (let ((ebox-scroll-step 1))
    (ebox-test-with-mounted (buffer _root
                             '(column (text "Header")
                                      (box :width (ch 4) :height (lh 2)
                                           :overflow scroll
                                           (column (text "A") (text "B") (text "C")))))
      (save-window-excursion
        (switch-to-buffer buffer)
        (goto-char (point-min))
        ;; The pointer sits in the header, where no scroll region responds;
        ;; the window used to scroll the whole page, shifting the header too.
        (let ((posn (posn-at-x-y 0 0 (selected-window))))
          (ebox-wheel-scroll-down (list 'wheel-down posn))
          (ebox-wheel-scroll-down (list 'wheel-down posn))
          (should (= (window-start) (point-min))))
        (should (string-prefix-p "Header" (ebox-test-buffer-text buffer)))))))

(ert-deftest ebox-page-scroll-commands-accept-explicit-line-counts ()
  (ebox-test-with-mounted (buffer root
                           '(box :id "scroller" :width (ch 4) :height (lh 2)
                                 :overflow scroll
                                 (column
                                  (text "A") (text "B") (text "C") (text "D"))))
    (goto-char (point-min))
    (ebox-scroll-page-down 2)
    (should (equal (ebox-test-buffer-text buffer) "C 
D "))
    (ebox-scroll-page-up 1)
    (should (equal (ebox-test-buffer-text buffer) "B 
C "))))

(defmacro ebox-test-with-session (spec &rest body)
  "Mount SPEC (BUFFER ROOT INPUT SESSION &rest OPTIONS), edit #field, run BODY.
OPTIONS are passed to `ebox-input-begin'.  The buffer is selected so
keyboard macros reach it."
  (declare (indent 1))
  (pcase-let ((`(,buffer ,root ,input ,session . ,options) spec))
    `(ebox-test-with-mounted (,buffer ,root ,input :width 400)
       (switch-to-buffer ,buffer)
       (let ((,session (ebox-input-begin ,buffer (car (ebox-selector-query ,root "#field"))
                                         ,@options)))
         ,@body))))

(ert-deftest ebox-input-session-edits-the-value-inside-the-node-layout ()
  (let (changes)
    (ebox-test-with-session (buffer root '(column (text "top")
                                                  (box :width (ch 8) :padding-inline (ch 1)
                                                       :border ((px 1) solid "#ff0000")
                                                       (text :id "field" "abc"))
                                                  (text "bottom"))
                                    session :on-change (lambda (value) (push value changes)))
      (should (eq (ebox-input-active-p buffer) session))
      (should (equal (ebox-input-text session) "abc"))
      (execute-kbd-macro (kbd "x y"))
      (should (equal (ebox-input-text session) "abcxy"))
      (should (equal (reverse changes) '("abcx" "abcxy")))
      ;; The value wraps inside the padded box and the box grows.
      (should (equal (ebox-test-buffer-text buffer)
                     "top \n│ abcx │ \n│ y  │ \nbottom "))
      (execute-kbd-macro (kbd "DEL"))
      (should (equal (ebox-test-buffer-text buffer) "top \n│ abcx │ \nbottom "))
      ;; The <backspace> key deletes too, although the buffer binds it to scroll.
      (execute-kbd-macro [backspace])
      (should (equal (ebox-input-text session) "abc"))
      (execute-kbd-macro "x")
      (should (equal (ebox-input-end session) "abcx"))
      (should-not (ebox-input-active-p buffer))
      (should (equal (ebox-test-buffer-text buffer) "top \n│ abcx │ \nbottom ")))))

(ert-deftest ebox-input-session-runs-native-editing-commands-on-the-value ()
  (ebox-test-with-session (buffer root '(column (text :id "field" "one two")) session)
    (execute-kbd-macro (kbd "M-b M-d C-a C-k C-y C-y"))
    (should (equal (ebox-input-text session) "one one "))
    (execute-kbd-macro (kbd "C-a x y C-/"))
    (should (equal (ebox-input-text session) "one one "))
    (execute-kbd-macro (kbd "C-SPC C-e C-w"))
    (should (equal (ebox-input-text session) ""))))

(ert-deftest ebox-input-session-keymap-separates-value-and-buffer-commands ()
  (let* ((submitted nil)
         (map (let ((map (make-sparse-keymap)))
                (define-key map (kbd "C-j") #'newline)
                (define-key map (kbd "RET")
                            (lambda () (interactive) (setq submitted (current-buffer))))
                map)))
    (ebox-test-with-session (buffer root '(column (text :id "field" "ab")) session :keymap map)
      (execute-kbd-macro (kbd "C-j c d RET"))
      (should (equal (ebox-input-text session) "ab\ncd"))
      (should (eq submitted buffer))
      ;; Up moves by painted rows and keeps the column.
      (execute-kbd-macro (kbd "C-b C-p X"))
      (should (equal (ebox-input-text session) "aXb\ncd")))))

(defun ebox-test-press-at (buffer pos &optional prefix)
  "Return a primary press and release at BUFFER position POS with PREFIX."
  (let ((posn (list (get-buffer-window buffer) pos '(0 . 0) 0 nil pos
                    '(0 . 0) nil '(0 . 0) '(1 . 1)))
        (prefix (or prefix "")))
    (let ((count (if (string-empty-p prefix) 1 2)))
      (vector (list (intern (concat prefix "down-mouse-1")) posn count)
              (list (intern (concat prefix "mouse-1")) posn count)))))

(ert-deftest ebox-input-session-pointer-places-caret-and-leaves-outside ()
  (let ((left 0))
    (ebox-test-with-session (buffer root '(column (box :width (ch 12) :padding-inline (ch 1)
                                                       (text :id "field" "abc def"))
                                                  (text "outside"))
                                    session :on-leave (lambda () (setq left (1+ left))))
      (let ((at (lambda (text) (with-current-buffer buffer
                                 (save-excursion (goto-char (point-min))
                                                 (search-forward text)
                                                 (match-beginning 0))))))
        ;; A press on a value character puts the caret before it.
        (execute-kbd-macro (vconcat (ebox-test-press-at buffer (funcall at "c d")) "X"))
        (should (equal (ebox-input-text session) "abXc def"))
        ;; A press on the field's padding stays in the field.
        (execute-kbd-macro (vconcat (ebox-test-press-at buffer (1- (funcall at "abX"))) "Y"))
        (should (equal (ebox-input-text session) "YabXc def"))
        (should (= left 0))
        ;; A double press selects the word under the pointer.
        (execute-kbd-macro (vconcat (ebox-test-press-at buffer (funcall at "def") "double-")
                                    (kbd "C-w")))
        (should (equal (ebox-input-text session) "YabXc "))
        ;; A press elsewhere reports leaving the field.
        (execute-kbd-macro (ebox-test-press-at buffer (funcall at "outside")))
        (should (= left 1))))))

(defvar ns-working-text)

(ert-deftest ebox-input-session-shows-input-method-preedit-in-layout ()
  (let ((native (lookup-key special-event-map [ns-put-working-text])))
    (ebox-test-with-session (buffer root '(column (box :width (ch 6) (text :id "field" "ab"))
                                                  (text "end"))
                                    session)
      ;; Emacs runs input-method events from `special-event-map' outside the
      ;; command loop.
      (let ((ns-working-text "pinyin"))
        (call-interactively (lookup-key special-event-map [ns-put-working-text])))
      ;; The working text reflows inside the field instead of overflowing it.
      (should (equal (ebox-test-buffer-text buffer) "abpiny \nin  \nend "))
      (should (equal (ebox-input-text session) "ab"))
      (call-interactively (lookup-key special-event-map [ns-unput-working-text]))
      (execute-kbd-macro "拼")
      (should (equal (ebox-input-text session) "ab拼"))
      (should (equal (ebox-test-buffer-text buffer) "ab拼  \nend "))
      (ebox-input-end session)
      ;; Ending the last session restores the binding Emacs had before.
      (should (eq (lookup-key special-event-map [ns-put-working-text]) native)))))

(ert-deftest ebox-input-session-follows-external-text ()
  (ebox-test-with-session (buffer root '(column (text :id "field" "abc")) session)
    (let ((field (ebox-input-session-node session)))
      (execute-kbd-macro (kbd "x"))
      (ebox-node-set-text field "abcx")
      (execute-kbd-macro (kbd "C-/"))
      (should (equal (ebox-input-text session) "abc"))
      (ebox-node-set-text field "reset")
      (should (equal (ebox-input-text session) "reset"))
      (should (equal (ebox-test-buffer-text buffer) "reset "))
      (execute-kbd-macro (kbd "!"))
      (should (equal (ebox-input-text session) "reset!")))))

(ert-deftest ebox-input-session-relayouts-during-editing ()
  (ebox-test-with-session (buffer root '(column (text :id "field" "abc")
                                                (box :width (vw 50) "half"))
                                  session)
    (should (ebox-mount-set-viewport buffer 200 10))
    (should (equal (ebox-mount-viewport buffer) '(200 . 10)))
    (execute-kbd-macro (kbd "d"))
    (should (equal (ebox-input-text session) "abcd"))
    (should (string-prefix-p "abcd" (ebox-test-buffer-text buffer)))))

;; Keys typed at a mounted canvas outside a session must not edit its
;; content, while a session receives ordinary printing keys.
(ert-deftest ebox-canvas-ignores-printing-keys-outside-input-sessions ()
  (ebox-test-with-mounted (buffer root '(box (text :id "field" "abc")))
    (let ((field (car (ebox-selector-query root "#field"))))
      (switch-to-buffer buffer)
      (goto-char (point-min))
      (should-not (eq (key-binding (kbd "x")) #'self-insert-command))
      (ignore-errors (execute-kbd-macro (kbd "x")))
      (should (equal (ebox-test-buffer-text buffer) "abc "))
      (let ((session (ebox-input-begin buffer field)))
        (execute-kbd-macro (kbd "x"))
        (should (equal (ebox-input-end session) "abcx")))
      (ignore-errors (execute-kbd-macro (kbd "y")))
      (should (equal (ebox-test-buffer-text buffer) "abcx ")))))

(ert-deftest ebox-input-session-reuses-caret-and-undo ()
  "A second session on the same text resumes its caret and undo history."
  (ebox-test-with-session (buffer root '(box (text :id "field" "value")) session)
    (execute-kbd-macro (kbd "A B"))
    (should (equal (ebox-input-text session) "valueAB"))
    (execute-kbd-macro (kbd "<left> <left>"))
    (should (equal (ebox-input-end session) "valueAB"))
    (let ((second (ebox-input-begin buffer (car (ebox-selector-query root "#field")))))
      (execute-kbd-macro "X")
      (should (equal (ebox-input-text second) "valueXAB"))
      (execute-kbd-macro (kbd "C-/"))
      (should (equal (ebox-input-text second) "valueAB"))
      (ebox-input-end second)))
  (ebox-test-with-session (buffer root '(box (text :id "field" "value")) session :caret 0)
    (execute-kbd-macro "X")
    (should (equal (ebox-input-text session) "Xvalue"))))

(ert-deftest ebox-input-session-validates-lifecycle ()
  (ebox-test-with-mounted (buffer root '(box :id "box" (text :id "field" "abc")))
    (let ((field (car (ebox-selector-query root "#field"))))
      (should-error (ebox-input-begin buffer (car (ebox-selector-query root "#box")))
                    :type 'ebox-input-error)
      (should-error (ebox-input-begin buffer field :keymap 'none) :type 'ebox-input-error)
      (let ((session (ebox-input-begin buffer field)))
        (should (eq (ebox-input-session-node session) field))
        (should-error (ebox-input-begin buffer field) :type 'ebox-input-error)
        (ebox-input-end session)
        (should-not (ebox-input-text session))
        (should-not (ebox-input-end session)))
      (let ((session (ebox-input-begin buffer field)))
        (ebox-unmount-buffer buffer)
        (should-not (ebox-input-active-p buffer))
        (should-not (ebox-input-text session))))))

(ert-deftest ebox-call-with-input-returns-reader-value-and-closes-session ()
  (ebox-test-with-mounted (buffer root '(column (box :id "field" :tab-index 0 "abc")
                                                 (box :id "other" :tab-index 0 "def")))
    (let ((field (car (ebox-selector-query root "#field"))))
      (ebox-focus (car (ebox-selector-query root "#other")) buffer)
      (should (equal (ebox-call-with-input field (lambda () "reader-value") buffer)
                     "reader-value"))
      ;; The input target keeps logical focus after the reader returns.
      (should (eq (ebox-focused-node buffer) field))
      (should-not (ebox-input-active-p buffer))
      (should (string-prefix-p "abc" (ebox-test-buffer-text buffer))))))

(ert-deftest ebox-fixed-flex-text-growth-preserves-following-content ()
  "Child height changes replace fixed flex rows, never insert root rows."
  (let ((ebox-viewport-width 400) (ebox-viewport-height 15))
    (dolist (overflow '(hidden scroll))
      (ebox-test-with-mounted
          (buffer root `(column
                         (text "HEADER")
                         (flex :height (lh 5) :flex-direction column :overflow ,overflow
                               (text :id "field" ""))
                         (text :id "footer" "FOOTER"))
                  :width 400 :height 15)
        (let ((field (car (ebox-selector-query root "#field")))
              (footer (car (ebox-selector-query root "#footer"))))
          (dolist (count '(1 2 3 5 6 8 2 0 12 1))
            (ebox-node-set-text
             field (mapconcat #'number-to-string (number-sequence 1 count) "\n"))
            (ebox-node-set-text footer (format "FOOTER %d" count))
            (let ((actual (ebox-test-buffer-text buffer))
                  (expected (substring-no-properties (ebox-render (ebox-node-copy root))))
                  (footer-row (plist-get (ebox-node-geometry footer) :y)))
              (should (equal actual expected))
              (should (= footer-row 6)))))))))

(ert-deftest ebox-fixed-flex-native-multiline-edit-preserves-following-content ()
  "Newlines, clearing and undo cannot corrupt siblings outside the editor."
  (let ((ebox-viewport-width 400) (ebox-viewport-height 15))
    (ebox-test-with-session
        (buffer root '(column
                       (flex :height (lh 5) :flex-direction column :overflow hidden
                             (text :id "field" ""))
                       (text :id "footer" "FOOTER"))
                session)
      (let ((footer (car (ebox-selector-query root "#footer"))))
        (dotimes (round 3)
          (execute-kbd-macro (vconcat "one" [return] "two" [return] "three" [return]
                                     "four" [return] "five" [return] "six" [return]
                                     "seven" [return] "eight"))
          (dolist (keys (list nil (kbd "C-x h C-w") (kbd "C-/") (kbd "C-x h C-w")))
            (when keys (execute-kbd-macro keys))
            (ebox-node-set-text footer (format "FOOTER %d" round))
            (let ((actual (ebox-test-buffer-text buffer))
                  (expected (substring-no-properties (ebox-render (ebox-node-copy root)))))
              (should (equal actual expected))))
          (should (equal (ebox-input-text session) "")))
        (ebox-input-end session)))))

(ert-deftest ebox-input-opening-click-is-not-an-outside-click ()
  "Opening from a button survives release; a later outside click still leaves."
  (let ((buffer (generate-new-buffer " *input opening click*"))
        field session (leaves 0))
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer buffer)
          (let* ((start (lambda ()
                          (setq session
                                (ebox-input-begin
                                 buffer field
                                 :on-leave (lambda ()
                                             (cl-incf leaves)
                                             (ebox-input-end session))))))
                 (root (ebox-mount
                        buffer
                        (list 'column
                              (list 'box :id "edit" :keymap
                                    (ebox-keymap-create :activate start) "Edit")
                              (list 'column :height '(lh 4)
                                    :keymap (ebox-keymap-create :activate #'ignore)
                                    '(text :id "field" "")
                                    (list 'box :id "inside-control" :keymap
                                          (ebox-keymap-create :activate #'ignore) "Tool"))
                              (list 'box :id "outside" :keymap
                                    (ebox-keymap-create :activate #'ignore) "Outside"))
                        :width 400 :height 12)))
            (setq field (car (ebox-selector-query root "#field")))
            (cl-labels
                ((click (id)
                   (let* ((node (car (ebox-selector-query root id)))
                          (position (ebox-node-position node))
                          (posn (list (selected-window) position '(2 . 2) 0))
                          ;; Use the published cell's native keymap in batch
                          ;; too, where there is no graphical pixel hit tester.
                          (overriding-local-map (get-text-property position 'keymap)))
                     (execute-kbd-macro (vector (list 'down-mouse-1 posn)
                                                (list 'mouse-1 posn))))))
              (click "#edit")
              (let ((active (and (ebox-input-active-p buffer) t)))
                (should active))
              (should (= leaves 0))
              (execute-kbd-macro "abc")
              (should (equal (ebox-input-text session) "abc"))
              (click "#inside-control")
              (let ((active (and (ebox-input-active-p buffer) t)))
                (should active))
              (should (= leaves 0))
              (should (equal (ebox-input-text session) "abc"))
              (execute-kbd-macro (kbd "DEL DEL DEL"))
              (ebox-mount-set-viewport buffer 200 12)
              (execute-kbd-macro "x")
              (should (equal (ebox-input-text session) "x"))
              (click "#outside")
              (let ((active (and (ebox-input-active-p buffer) t)))
                (should-not active))
              (should (= leaves 1))
              (click "#edit")
              (let ((active (and (ebox-input-active-p buffer) t)))
                (should active))
              (should (= leaves 1)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;;; ebox-scroll-input-tests.el ends here
