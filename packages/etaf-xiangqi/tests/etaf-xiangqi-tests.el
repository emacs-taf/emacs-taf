;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-tests.el --- Public Xiangqi behavior
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-xiangqi)

(defun etaf-xiangqi-test--wait (session &optional predicate failure)
  "Await SESSION's painted board and PREDICATE; expect rejection with FAILURE."
  (let ((end (+ (float-time) 8)))
    (while (and (< (float-time) end)
                (not (memq (etaf-gamekit-status session) '(failed closed)))
                (or (not (eq (etaf-gamekit-status session) 'ready))
                    (plist-get (etaf-runtime-host-props-for
                                (etaf-runtime-for-buffer (etaf-gamekit-buffer session))
                                'xiangqi-new) :disabled)
                    (and predicate (not (funcall predicate)))))
      (accept-process-output nil 0.01)))
  (should (eq (etaf-gamekit-status session) 'ready))
  (if failure (should (etaf-gamekit-last-error session))
    (should-not (etaf-gamekit-last-error session)))
  (when predicate (should (funcall predicate))))

(defun etaf-xiangqi-test--close (session)
  "Dispose the application INSTANCE and its buffer."
  (when session (etaf-xiangqi-close session)))

(defun etaf-xiangqi-test--start (seed &optional opponent level)
  "Start an independent match with integer SEED, OPPONENT and LEVEL.
The application reads both variables when the view mounts, which happens
inside `etaf-gamekit-start'."
  (let ((etaf-xiangqi-opponent (or opponent etaf-xiangqi-opponent))
        (etaf-xiangqi-level (or level etaf-xiangqi-level)))
    (let* ((session (etaf-gamekit-start etaf-xiangqi-game :options (list :seed seed)))
           (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
      (etaf-runtime-refit runtime 1100 44)
      (etaf-xiangqi-test--wait session)
      (etaf-xiangqi-test--wait session (lambda () (etaf-host-ref-size runtime 'xiangqi-board)))
      session)))

(ert-deftest etaf-xiangqi-hot-seat-moves-and-undo-restores ()
  "Red and black alternate through the public board; undo restores the opening."
  (let ((session (etaf-xiangqi-test--start 11 'hot-seat)))
    (unwind-protect
        (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
               (before (etaf-gamekit-observation session)))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
          (should-not (equal before (etaf-gamekit-observation session)))
          (etaf-xiangqi-test--wait session (lambda () (equal 1 (etaf-gamekit-view session :player))))
          (should (consp (etaf-gamekit-view session :legal_actions)))
          (let* ((action (car (etaf-gamekit-view session :legal_actions)))
                 (ref (intern (format "xiangqi-move-%d" (plist-get action :id)))))
            (etaf-dispatch-event runtime 'xiangqi-show-moves 'press)
            (etaf-dispatch-event runtime ref 'press)
            (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 2)))
            (etaf-xiangqi-test--wait session (lambda () (equal 0 (etaf-gamekit-view session :player)))))
          (etaf-dispatch-event runtime 'xiangqi-undo 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
          (etaf-dispatch-event runtime 'xiangqi-undo 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 0)))
          (should (equal (plist-get before :observation) (etaf-gamekit-view session :observation))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-invalid-action-preserves-the-board ()
  "An action that is not legal for the side to move preserves the match."
  (let ((session (etaf-xiangqi-test--start 11 'hot-seat)))
    (unwind-protect
        (let ((before (etaf-gamekit-observation session)))
          (etaf-gamekit-action session "act" (list :action 1234567))
          (accept-process-output nil 0.3)
          (should (etaf-gamekit-last-error session))
          (should (equal before (etaf-gamekit-observation session))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-themes-preserve-the-match ()
  "Light/dark switching preserves the match, selection and board metrics."
  (let ((session (etaf-xiangqi-test--start 11 'hot-seat)))
    (unwind-protect
        (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
               (before (etaf-gamekit-observation session))
               (size (etaf-host-ref-size runtime 'xiangqi-board)))
          (etaf-focus runtime 'xiangqi-cell-6-4)
          (etaf-activate runtime)
          (dotimes (_ 2)
            (etaf-dispatch-event runtime 'xiangqi-theme 'press)
            (let ((after (etaf-gamekit-observation session))
                  (geometry (etaf-host-ref-size runtime 'xiangqi-board))
                  (focus (etaf-focused-host-ref runtime)))
              (should (equal before after))
              (should (equal size geometry))
              (should (eq focus 'xiangqi-cell-6-4))))
          (dolist (viewport '((1400 . 70) (1400 . 48) (950 . 44) (550 . 42) (1000 . 34) (320 . 20)))
            (etaf-runtime-refit runtime (car viewport) (cdr viewport))
            (let* ((table (etaf-host-ref-size runtime 'xiangqi-root))
                   (bounds (etaf-host-ref-bounds runtime 'xiangqi-root))
                   (surplus (max 0 (- (cdr viewport) (cdr table))))
                   (top (with-current-buffer (etaf-gamekit-buffer session)
                          (1- (line-number-at-pos (car bounds))))))
              (should (<= (abs (- top (* 0.4 surplus))) 1)))
            (let ((geometry (etaf-host-ref-size runtime 'xiangqi-board))
                  (focus (etaf-focused-host-ref runtime)))
              (should (equal size geometry))
              (should (eq focus 'xiangqi-cell-6-4))))
          (etaf-runtime-refit runtime 1100 44)
          (let ((next (etaf-direction 'up runtime)))
            (should (eq next 'xiangqi-cell-5-4)))
          (etaf-activate runtime)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-matches-are-independent ()
  "A move in one match cannot change a second match."
  (let ((first (etaf-xiangqi-test--start 11 'hot-seat)))
    (unwind-protect
        (let ((second (etaf-xiangqi-test--start 11 'hot-seat)))
          (unwind-protect
              (let ((before (etaf-gamekit-observation second))
                    (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer first))))
                (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
                (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
                (etaf-xiangqi-test--wait first (lambda () (= (etaf-gamekit-view first :action_count) 1)))
                (should (equal before (etaf-gamekit-observation second))))
            (etaf-xiangqi-test--close second)))
      (etaf-xiangqi-test--close first))))

(defun etaf-xiangqi-test--help-visible-p (runtime)
  "Whether RUNTIME exposes the shared help's close control."
  (cl-some (lambda (entry)
             (equal (plist-get (cdr entry) :aria-label) "关闭帮助"))
           (etaf-runtime-host-props-entries runtime)))

(ert-deftest etaf-xiangqi-dialog-and-escape-dismiss-one-layer ()
  "All help entries share a read-only modal; Escape closes it before clearing selection."
  (save-window-excursion
    (let* ((etaf-xiangqi-opponent 'hot-seat)
           (session (etaf-xiangqi-open 11)))
      (unwind-protect
          (let* ((buffer (etaf-gamekit-buffer session))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-xiangqi-test--wait session)
            (etaf-xiangqi-test--wait session (lambda () (etaf-host-ref-size runtime 'xiangqi-board)))
            (etaf-focus runtime 'xiangqi-cell-6-4)
            (etaf-activate runtime)
            (dolist (entry '("<f1>" button "?"))
              (etaf-focus runtime 'xiangqi-help)
              (let ((before (etaf-gamekit-observation session))
                    (windows (window-list)) (buffers (buffer-list)))
                (if (eq entry 'button) (etaf-activate runtime)
                  (execute-kbd-macro (kbd entry)))
                (let* ((visible (etaf-xiangqi-test--help-visible-p runtime))
                       (data (etaf-help-data runtime))
                       (title (plist-get data :title))
                       (notes (string-join (plist-get data :notes) " ")))
                  (should visible)
                  (should (equal title "中国象棋"))
                  (should (string-match-p "OpenSpiel Xiangqi" notes))
                  (execute-kbd-macro (kbd "? n u y o q"))
                  (let ((after (etaf-help-data runtime)))
                    (should (equal data after))))
                (should (equal windows (window-list)))
                (should (equal buffers (buffer-list)))
                (should (eq buffer (window-buffer)))
                (execute-kbd-macro (kbd "/ n ? <escape>"))
                (let ((visible (etaf-xiangqi-test--help-visible-p runtime))
                      (editing (not (null (etaf-text-input-active-p runtime)))))
                  (should visible)
                  (should-not editing))
                (execute-kbd-macro (kbd "<escape>"))
                (let ((after (etaf-gamekit-observation session))
                      (text (buffer-substring-no-properties (point-min) (point-max)))
                      (focus (etaf-focused-host-ref runtime))
                      (closed-again (etaf-help-close runtime)))
                  (should (equal before after))
                  (should (string-match-p "已选 红兵" text))
                  (should (eq focus 'xiangqi-help))
                  (should-not closed-again))))
            (execute-kbd-macro (kbd "<escape>"))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "已选" text))))
        (etaf-xiangqi-close session)))))

(ert-deftest etaf-xiangqi-help-survives-the-computer-reply ()
  "Computer search and paced presentation continue beneath help without stealing focus."
  (save-window-excursion
    (let* ((etaf-xiangqi-opponent 'computer-black)
           (etaf-xiangqi-level 'easy)
           (session (etaf-xiangqi-open 11)))
      (unwind-protect
          (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
            (etaf-xiangqi-test--wait session)
            (etaf-xiangqi-test--wait session (lambda () (etaf-host-ref-size runtime 'xiangqi-board)))
            (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
            (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
            (etaf-focus runtime 'xiangqi-help)
            (execute-kbd-macro (kbd "<f1>"))
            (let ((focus (etaf-focused-host-ref runtime))
                  (snapshot (etaf-help-data runtime)))
              (etaf-xiangqi-test--wait
               session (lambda () (= (etaf-gamekit-view session :action_count) 2)))
              (let ((after-focus (etaf-focused-host-ref runtime))
                    (after-data (etaf-help-data runtime))
                    (visible (etaf-xiangqi-test--help-visible-p runtime)))
                (should visible)
                (should (equal focus after-focus))
                (should (equal snapshot after-data))))
            (execute-kbd-macro (kbd "<escape>"))
            (let ((text (buffer-substring-no-properties (point-min) (point-max)))
                  (focus (etaf-focused-host-ref runtime)))
              (should (string-match-p "电脑：" text))
              (should (eq focus 'xiangqi-help)))
            (execute-kbd-macro "u")
            (etaf-xiangqi-test--wait
             session (lambda () (= (etaf-gamekit-view session :action_count) 0))))
        (etaf-xiangqi-close session)))))

(ert-deftest etaf-xiangqi-computer-replies-with-a-search-move ()
  "The default match answers a human move without a second local turn."
  (let ((session (etaf-xiangqi-test--start 11)))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 2)))
          (should (= 0 (etaf-gamekit-view session :player)))
          (should (= 0 (etaf-gamekit-view session :current_player)))
          (should (equal "search" (plist-get (etaf-gamekit-view session :bot) :policy)))
          (let ((report (etaf-gamekit-view session :bot)))
            (should (= 4 (plist-get report :requested_depth)))
            (should (<= 1 (plist-get report :depth) 4))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-computer-opening-move-arrives-first ()
  "With the computer on red, its opening move needs no local input."
  (let ((session (etaf-xiangqi-test--start 11 'computer-red)))
    (unwind-protect
        (progn
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
          (should (= 1 (etaf-gamekit-view session :player)))
          (should (= 1 (etaf-gamekit-view session :current_player)))
          ;; Before the human has moved, undo cannot just replay the opening.
          (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
            (let* ((props (etaf-runtime-host-props-for runtime 'xiangqi-undo))
                   (disabled (plist-get props :disabled)))
              (should disabled))
            (with-current-buffer (etaf-gamekit-buffer session)
              (call-interactively (key-binding (kbd "u"))))
            (etaf-xiangqi-test--wait session)
            (should (= 1 (etaf-gamekit-view session :action_count)))
            (etaf-dispatch-event runtime 'xiangqi-cell-3-4 'press)
            (etaf-dispatch-event runtime 'xiangqi-cell-4-4 'press)
            (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 3)))
            (etaf-dispatch-event runtime 'xiangqi-undo 'press)
            (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
            (should (= 1 (etaf-gamekit-view session :current_player)))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-computer-undo-restores-the-human-turn ()
  "One undo takes back the computer's reply and the human's own move."
  (let ((session (etaf-xiangqi-test--start 11 'computer-black)))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 2)))
          (etaf-dispatch-event runtime 'xiangqi-undo 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 0)))
          (should (eq t (etaf-gamekit-view session :can_redo)))
          (should (= 0 (etaf-gamekit-view session :player)))
          (etaf-dispatch-event runtime 'xiangqi-redo 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 2)))
          (should (= 0 (etaf-gamekit-view session :current_player)))
          (etaf-dispatch-event runtime 'xiangqi-new 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 0))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-settings-switch-to-hot-seat ()
  "The settings dialog hands both sides to the local player."
  (let ((session (etaf-xiangqi-test--start 11 'computer-black)))
    (unwind-protect
        (let* ((buffer (etaf-gamekit-buffer session))
               (runtime (etaf-runtime-for-buffer buffer)))
          (etaf-dispatch-event runtime 'xiangqi-settings 'press)
          (etaf-dispatch-event runtime 'xiangqi-opponent-hot-seat 'press)
          (with-current-buffer buffer (call-interactively (key-binding (kbd "<escape>"))))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
          (accept-process-output nil 0.5)
          (should (= 1 (etaf-gamekit-view session :action_count)))
          (should (= 1 (etaf-gamekit-view session :player)))
          (with-current-buffer buffer
            (should (string-match-p "同机双人" (buffer-substring-no-properties (point-min) (point-max))))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-settings-level-drives-the-search ()
  "The difficulty picker selects the search budget the backend uses."
  (let ((session (etaf-xiangqi-test--start 11 'computer-black)))
    (unwind-protect
        (let* ((buffer (etaf-gamekit-buffer session))
               (runtime (etaf-runtime-for-buffer buffer)))
          (etaf-dispatch-event runtime 'xiangqi-settings 'press)
          (etaf-dispatch-event runtime 'xiangqi-level-easy 'press)
          (with-current-buffer buffer (call-interactively (key-binding (kbd "<escape>"))))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 2)))
          (should (= 2 (plist-get (etaf-gamekit-view session :bot) :requested_depth))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-computer-rejection-stops-and-new-match-recovers ()
  "A bot rejection stays visible without retries, and New match recovers."
  (let ((session (etaf-xiangqi-test--start 11 'hot-seat)))
    (unwind-protect
        (let* ((buffer (etaf-gamekit-buffer session))
               (runtime (etaf-runtime-for-buffer buffer)))
          (etaf-gamekit-action session "bot" '(:depth 0))
          (etaf-xiangqi-test--wait session nil t)
          (etaf-dispatch-event runtime 'xiangqi-settings 'press)
          (etaf-dispatch-event runtime 'xiangqi-opponent-computer-red 'press)
          (with-current-buffer buffer (call-interactively (key-binding (kbd "<escape>"))))
          (accept-process-output nil 0.1)
          (etaf-xiangqi-test--wait session nil t)
          (should (= 0 (etaf-gamekit-view session :action_count)))
          (let ((text (with-current-buffer buffer
                        (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "操作失败" text))
            (should-not (string-match-p "电脑思考中" text)))
          (etaf-dispatch-event runtime 'xiangqi-new 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
          (should (= 1 (etaf-gamekit-view session :current_player))))
      (etaf-xiangqi-test--close session))))

(defun etaf-xiangqi-test--text (session)
  "Return SESSION's displayed text without live text properties."
  (with-current-buffer (etaf-gamekit-buffer session)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-xiangqi-test--native-reply (session count)
  "Await native COUNT without waiting for its deliberately delayed presentation."
  (let ((deadline (+ (float-time) 5)))
    (while (and (< (float-time) deadline)
                (not (and (eq (etaf-gamekit-status session) 'ready)
                          (equal count (etaf-gamekit-view session :action_count)))))
      (accept-process-output nil 0.005)))
  (let ((actual (etaf-gamekit-view session :action_count))
        (failure (etaf-gamekit-last-error session)))
    (should (= count actual))
    (should-not failure)))

(ert-deftest etaf-xiangqi-fast-reply-waits-and-keeps-visible-move-markers ()
  "A fast reply leaves reading time, then exposes its endpoints and caption."
  (let ((session (etaf-xiangqi-test--start 11 'computer-black 'easy)))
    (unwind-protect
        (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
               (started (float-time)))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--native-reply session 2)
          (let* ((text (etaf-xiangqi-test--text session))
                 (disabled (plist-get (etaf-runtime-host-props-for runtime 'xiangqi-new) :disabled)))
            (should disabled)
            (should (string-match-p "电脑思考中" text))
            (should-not (string-match-p "电脑：" text)))
          (etaf-xiangqi-test--wait session)
          (should (>= (- (float-time) started) 0.55))
          (let* ((report (etaf-gamekit-view session :bot))
                 (label (plist-get report :label))
                 (matched (string-match "(\\([0-9]+\\),\\([0-9]+\\))-(\\([0-9]+\\),\\([0-9]+\\))" label))
                 (from (and matched (intern (format "xiangqi-cell-%s-%s" (match-string 1 label) (match-string 2 label)))))
                 (to (and matched (intern (format "xiangqi-cell-%s-%s" (match-string 3 label) (match-string 4 label))))))
            (should matched)
            (dolist (entry (list (cons from "电脑起点") (cons to "电脑落点")))
              (let ((caption (plist-get (etaf-runtime-host-props-for runtime (car entry)) :aria-label)))
                (should (string-match-p (cdr entry) caption))))
            (dotimes (_ 2)
              (etaf-dispatch-event runtime 'xiangqi-theme 'press)
              (let ((text (etaf-xiangqi-test--text session)))
                (should (string-match-p "电脑：" text)))))
          (let ((snapshot (make-temp-file "xiangqi-feedback-" nil ".json")))
            (unwind-protect
                (progn
                  (etaf-gamekit-action session "save" (list :path snapshot))
                  (etaf-xiangqi-test--wait session)
                  (etaf-gamekit-action session "load" (list :path snapshot))
                  (etaf-xiangqi-test--wait session)
                  (let ((text (etaf-xiangqi-test--text session)))
                    (should-not (string-match-p "电脑：" text))))
              (delete-file snapshot)))
          (etaf-dispatch-event runtime 'xiangqi-undo 'press)
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 0)))
          (let ((text (etaf-xiangqi-test--text session)))
            (should-not (string-match-p "电脑：" text))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-reset-and-close-discard-delayed-replies ()
  "A reset or close supersedes a held computer reply without a late ghost move."
  (let ((session (etaf-xiangqi-test--start 11 'computer-black 'easy)))
    (unwind-protect
        (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
               (buffer (etaf-gamekit-buffer session)))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--native-reply session 2)
          ;; Public backend callers can reset even while the UI is presenting.
          (etaf-gamekit-action session "reset")
          (etaf-xiangqi-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 0)))
          (let ((until (+ (float-time) 0.65)))
            (while (< (float-time) until) (accept-process-output nil 0.02)))
          (let ((text (etaf-xiangqi-test--text session)))
            (should-not (string-match-p "电脑：\\|电脑落子中" text)))
          (should (= 0 (etaf-gamekit-view session :action_count)))
          (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
          (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
          (etaf-xiangqi-test--native-reply session 2)
          (etaf-xiangqi-close session)
          (let ((until (+ (float-time) 0.65)))
            (while (< (float-time) until) (accept-process-output nil 0.02)))
          (let ((status (etaf-gamekit-status session)) (alive (buffer-live-p buffer)))
            (should (eq status 'closed))
            (should-not alive)))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-winning-reply-keeps-its-caption ()
  "A paced winning move names its winner without losing the final move caption."
  (let ((etaf-animation-enabled nil)
        (session (etaf-xiangqi-test--start 11 'hot-seat 'easy)))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
          (cl-loop for action in '(6307 1792 635 7464 458 373 7734 1184 723 9
                                  271 2284 96 823 547 1265 632 3076 180 454)
                   for count from 1
                   do (etaf-gamekit-action session "act" (list :action action))
                   do (etaf-xiangqi-test--wait session
                        (lambda () (= (etaf-gamekit-view session :action_count) count))))
          (etaf-dispatch-event runtime 'xiangqi-settings 'press)
          (etaf-dispatch-event runtime 'xiangqi-opponent-computer-red 'press)
          (with-current-buffer (etaf-gamekit-buffer session)
            (call-interactively (key-binding (kbd "<escape>"))))
          (etaf-xiangqi-test--wait session (lambda () (eq t (etaf-gamekit-view session :terminal))))
          (let ((text (etaf-xiangqi-test--text session)))
            (should (string-match-p "红方胜" text))
            (should (string-match-p "电脑：红炮 b2 → b9" text))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-capture-description-with-reduced-motion ()
  "The terminal/reduced-motion path still names a captured piece and endpoints."
  (let* ((etaf-animation-enabled nil)
         (session (etaf-xiangqi-test--start 11 'computer-red 'easy)))
    (unwind-protect
        (let ((text (etaf-xiangqi-test--text session)))
          (should (string-match-p "电脑：红炮" text))
          (should (string-match-p "吃黑馬" text))
          (should-not (string-match-p "电脑落子中" text)))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-slow-search-does-not-add-a-second-delay ()
  "A search longer than the reading interval lands immediately in a terminal."
  (let* ((etaf-xiangqi-opponent 'computer-red) (etaf-xiangqi-level 'hard)
         (session (etaf-gamekit-start etaf-xiangqi-game :options '(:seed 11)))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
    (unwind-protect
        (progn
          (etaf-runtime-refit runtime 1100 44)
          (etaf-xiangqi-test--native-reply session 1)
          (let ((replied (float-time))
                (elapsed (plist-get (etaf-gamekit-view session :bot) :elapsed)))
            (should (> elapsed 0.6))
            (etaf-xiangqi-test--wait session)
            (should (< (- (float-time) replied) 0.3))))
      (etaf-xiangqi-test--close session))))

(defun etaf-xiangqi-test--press (runtime from to)
  "Press FROM and then TO on RUNTIME's board."
  (etaf-dispatch-event runtime (intern (format "xiangqi-cell-%d-%d" (car from) (cdr from))) 'press)
  (etaf-dispatch-event runtime (intern (format "xiangqi-cell-%d-%d" (car to) (cdr to))) 'press))

(ert-deftest etaf-xiangqi-check-is-announced-and-explains-an-immobile-stone ()
  "A checked side learns why most stones cannot move, and can still answer."
  (let ((session (etaf-xiangqi-test--start 11 'hot-seat)))
    (unwind-protect
        (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
               (moves '(((7 . 1) (0 . 1)) ((0 . 0) (0 . 1)) ((7 . 7) (0 . 7))
                        ((0 . 8) (0 . 7)) ((9 . 1) (7 . 2)) ((2 . 1) (2 . 4))
                        ((6 . 2) (5 . 2)) ((3 . 4) (4 . 4)) ((6 . 4) (5 . 4))
                        ((4 . 4) (5 . 4)))))
          ;; Black's cannon on e7 aims at the red general through the soldier
          ;; that lands on e4, so the last position is check.
          (cl-loop for (from to) in moves for ply from 1
                   do (etaf-xiangqi-test--press runtime from to)
                   do (etaf-xiangqi-test--wait
                       session (lambda () (= ply (etaf-gamekit-view session :action_count)))))
          (should (string-match-p "被将军" (etaf-xiangqi-test--text session)))
          ;; The right-hand horse cannot reach the checking line.
          (etaf-dispatch-event runtime 'xiangqi-cell-9-7 'press)
          (should (string-match-p "解不了将" (etaf-xiangqi-test--text session)))
          ;; An advisor that interposes on e1 answers the check.
          (etaf-xiangqi-test--press runtime (cons 9 3) (cons 8 4))
          (etaf-xiangqi-test--wait session (lambda () (= 11 (etaf-gamekit-view session :action_count))))
          (should-not (string-match-p "被将军" (etaf-xiangqi-test--text session))))
      (etaf-xiangqi-test--close session))))

(ert-deftest etaf-xiangqi-hosted-session-renders-in-its-host ()
  "A session prepared for a host mounts nothing itself and repaints there."
  (let* ((session (etaf-xiangqi-create 11))
         (host (generate-new-buffer " *xiangqi host*")))
    (unwind-protect
        (progn
          ;; The session owns state only: its own buffer stays unmounted, so
          ;; the host is the single rendering of this match.
          (should-not (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
          (etaf-mount host (etaf-xiangqi-view session))
          (let ((runtime (etaf-runtime-for-buffer host))
                (deadline (+ (float-time) 8)))
            (etaf-runtime-refit runtime 1100 44)
            (while (and (< (float-time) deadline)
                        (or (not (eq (etaf-gamekit-status session) 'ready))
                            (not (etaf-host-ref-size runtime 'xiangqi-board))))
              (accept-process-output nil 0.01)
              (etaf-runtime-flush runtime))
            (should (eq (etaf-gamekit-status session) 'ready))
            (let ((before (with-current-buffer host
                            (buffer-substring-no-properties (point-min) (point-max)))))
              (etaf-dispatch-event runtime 'xiangqi-cell-6-4 'press)
              (etaf-dispatch-event runtime 'xiangqi-cell-5-4 'press)
              ;; The computer's reply has to reach the host's own buffer.
              (while (and (< (float-time) deadline)
                          (not (= 2 (or (etaf-gamekit-view session :action_count) 0))))
                (accept-process-output nil 0.01)
                (when-let* ((live (etaf-runtime-for-buffer host)))
                  (etaf-runtime-flush live)))
              (should (= 2 (etaf-gamekit-view session :action_count)))
              (should-not (equal before
                                 (with-current-buffer host
                                   (buffer-substring-no-properties
                                    (point-min) (point-max))))))))
      (when-let* ((runtime (etaf-runtime-for-buffer host)))
        (etaf-unmount runtime))
      (kill-buffer host)
      (etaf-xiangqi-test--close session))))

(provide 'etaf-xiangqi-tests)
;;; etaf-xiangqi-tests.el ends here
