;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire-tests.el --- Public application behavior
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'etaf-solitaire)

(defun etaf-solitaire-test--wait (session &optional predicate)
  "Await SESSION's dealt table, painted board and optional PREDICATE.

A hosted session paints no board of its own, so the deal itself is the
readiness signal: a mount that races the deal renders the placeholder instead
of the cards."
  (let ((end (+ (float-time) 6)))
    (while (and (< (float-time) end)
                (not (memq (etaf-gamekit-status session) '(failed closed)))
                (or (not (eq (etaf-gamekit-status session) 'ready))
                    (null (plist-get (etaf-gamekit-view session) :observation))
                    (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
                      (and runtime
                           (not (etaf-host-ref-size runtime 'solitaire-board))))
                    (and predicate (not (funcall predicate)))))
      (accept-process-output nil 0.01)))
  (should (eq (etaf-gamekit-status session) 'ready))
  (should-not (etaf-gamekit-last-error session))
  (when predicate (should (funcall predicate))))

(defun etaf-solitaire-test--close (session)
  "Dispose the application INSTANCE and its buffer."
  (when session (etaf-solitaire-close session)))

(defun etaf-solitaire-test--key (key)
  "Run the native command bound to KEY in the application buffer."
  (let ((command (key-binding (kbd key))))
    (should (commandp command))
    (call-interactively command)))

(ert-deftest etaf-solitaire-card-input-moves-native-cards-and-restores-history ()
  "Selecting a card and its foundation changes native state; undo/redo restore it."
  (let ((session (etaf-gamekit-start etaf-solitaire-game :options '(:seed 11))))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
          (etaf-runtime-refit runtime 1100 44)
          (etaf-solitaire-test--wait session)
          (let ((before (etaf-gamekit-view session :observation)))
            (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)
            (etaf-dispatch-event runtime 'solitaire-foundation-2 'press)
            (etaf-solitaire-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
            (let ((after (etaf-gamekit-view session :observation)))
              (should-not (equal before after))
              (etaf-dispatch-event runtime 'solitaire-undo 'press)
              (etaf-solitaire-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 0)))
              (should (equal before (etaf-gamekit-view session :observation)))
              (etaf-dispatch-event runtime 'solitaire-redo 'press)
              (etaf-solitaire-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
              (should (equal after (etaf-gamekit-view session :observation))))))
      (etaf-solitaire-test--close session))))

(ert-deftest etaf-solitaire-waste-activation-follows-the-displayed-card ()
  "A retained waste control activates its current card after browsing."
  (let ((session (etaf-gamekit-start etaf-solitaire-game :options '(:seed 11))))
    (unwind-protect
        (let* ((buffer (etaf-gamekit-buffer session))
               (runtime (etaf-runtime-for-buffer buffer))
               (steps 0))
          (etaf-runtime-refit runtime 1100 44)
          (etaf-solitaire-test--wait session)
          (while (and (< steps 24)
                      (not (equal (plist-get (etaf-runtime-host-props-for runtime 'solitaire-waste)
                                              :aria-label)
                                  "3 of hearts")))
            (etaf-dispatch-event runtime 'solitaire-draw 'press)
            (cl-incf steps))
          (should (< steps 24))
          (should (> steps 0))
          (etaf-dispatch-event runtime 'solitaire-waste 'press)
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "已选 3♥" text))))
          (should (= (etaf-gamekit-view session :action_count) 0)))
      (etaf-solitaire-test--close session))))

(ert-deftest etaf-solitaire-themes-and-resize-preserve-the-deal ()
  "Light/dark switching and narrow layouts preserve state, selection and card metrics."
  (let* ((etaf-solitaire-appearance 'light)
         (session (etaf-gamekit-start etaf-solitaire-game :options '(:seed 11))))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
          (etaf-runtime-refit runtime 1100 44)
          (etaf-solitaire-test--wait session)
          (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)
          (let ((before (etaf-gamekit-observation session))
                (card (etaf-host-ref-size runtime 'solitaire-card-A♣)))
            ;; Instance-owned keyboard callbacks keep reading the live refs
            ;; after selection and earlier theme publications.
            (etaf-focus runtime 'solitaire-card-A♣)
            (with-current-buffer (etaf-gamekit-buffer session)
              (dolist (next-label '("浅色" "暗色"))
                (etaf-solitaire-test--key "t")
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p next-label text))
                  (should (string-match-p "已选 A♣" text)))))
            (dotimes (_ 2)
              (etaf-dispatch-event runtime 'solitaire-theme 'press)
              (should (equal before (etaf-gamekit-observation session)))
              (should (equal card (etaf-host-ref-size runtime 'solitaire-card-A♣))))
            (dolist (rows '(70 44 30))
              (etaf-runtime-refit runtime 1100 rows)
              (let* ((size (etaf-host-ref-size runtime 'solitaire-root))
                     (bounds (etaf-host-ref-bounds runtime 'solitaire-root))
                     (surplus (max 0 (- rows (cdr size))))
                     (top (with-current-buffer (etaf-gamekit-buffer session)
                            (1- (line-number-at-pos (car bounds))))))
                (should (<= (abs (- top (* 0.4 surplus))) 1)))
              (let ((current-card (etaf-host-ref-size runtime 'solitaire-card-A♣)))
                (should (equal card current-card))))
            (etaf-runtime-refit runtime 90 32)
            (should (equal card (etaf-host-ref-size runtime 'solitaire-card-A♣)))
            (should (equal before (etaf-gamekit-observation session)))
            (etaf-dispatch-event runtime 'solitaire-foundation-2 'press)
            (etaf-solitaire-test--wait session (lambda () (= (etaf-gamekit-view session :action_count) 1)))))
      (etaf-solitaire-test--close session))))

(ert-deftest etaf-solitaire-embedded-escape-releases-the-host-after-selection ()
  "Embedded help, selected cards and host dismissal each consume one Escape."
  (let ((session (etaf-solitaire-create 11))
        (buffer (generate-new-buffer " *solitaire-embedded-escape*"))
        (exits 0))
    (unwind-protect
        (progn
          (etaf-solitaire-test--wait session)
          (etaf-mount
           buffer (etaf-node 'column
                             (list :key-scope 'local
                                   :on-dismiss (lambda () (cl-incf exits)))
                             (list (etaf-solitaire-view session))))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-runtime-refit runtime 1100 44)
            (etaf-focus runtime 'solitaire-card-A♣)
            (etaf-activate runtime)
            (etaf-help runtime)
            (with-current-buffer buffer
              (etaf-solitaire-test--key "<escape>")
              (should (= exits 0))
              (should (string-match-p "已选 A♣"
                                      (buffer-substring-no-properties (point-min) (point-max))))
              (etaf-solitaire-test--key "<escape>")
              (should (= exits 0))
              (should-not (string-match-p "已选"
                                          (buffer-substring-no-properties (point-min) (point-max))))
              (etaf-solitaire-test--key "<escape>")
              (should (= exits 1)))
            (should (= (etaf-gamekit-view session :action_count) 0))
            (should (eq (etaf-gamekit-status session) 'ready))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer)
      (etaf-solitaire-test--close session))))

(ert-deftest etaf-solitaire-escape-dismisses-the-selection ()
  "Framework Escape clears a picked card so a later target press is inert."
  (let ((session (etaf-gamekit-start etaf-solitaire-game :options '(:seed 11))))
    (unwind-protect
        (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
          (etaf-runtime-refit runtime 1100 44)
          (etaf-solitaire-test--wait session)
          (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)
          (with-current-buffer (etaf-gamekit-buffer session)
            (etaf-solitaire-test--key "<escape>"))
          (should-error (etaf-dispatch-event runtime 'solitaire-foundation-2 'press)
                        :type 'etaf-event-error)
          (should (= (etaf-gamekit-view session :action_count) 0)))
      (etaf-solitaire-test--close session))))

(defun etaf-solitaire-test--help-visible-p (runtime)
  "Whether RUNTIME exposes the shared help's close control."
  (cl-some (lambda (entry)
             (equal (plist-get (cdr entry) :aria-label) "关闭帮助"))
           (etaf-runtime-host-props-entries runtime)))

(ert-deftest etaf-solitaire-help-entries-preserve-the-selected-card ()
  "F1, the toolbar and question mark share read-only help without clearing selection."
  (save-window-excursion
    (let ((session (etaf-solitaire-open 11)))
      (unwind-protect
          (let* ((buffer (etaf-gamekit-buffer session))
                 (runtime (etaf-runtime-for-buffer buffer)))
            (etaf-solitaire-test--wait session)
            (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)
            (dolist (entry '("<f1>" button "?"))
              (etaf-focus runtime 'solitaire-help)
              (let ((before (etaf-gamekit-observation session))
                    (windows (window-list)) (buffers (buffer-list)))
                (if (eq entry 'button) (etaf-activate runtime)
                  (execute-kbd-macro (kbd entry)))
                (let* ((visible (etaf-solitaire-test--help-visible-p runtime))
                       (data (etaf-help-data runtime))
                       (title (plist-get data :title))
                       (notes (string-join (plist-get data :notes) " ")))
                  (should visible)
                  (should (equal title "纸牌接龙"))
                  (should (string-match-p (regexp-quote "K+ Klondike") notes))
                  (execute-kbd-macro (kbd "? d h n u y q"))
                  (let ((after (etaf-help-data runtime)))
                    (should (equal data after))))
                (should (equal windows (window-list)))
                (should (equal buffers (buffer-list)))
                (should (eq buffer (window-buffer)))
                (execute-kbd-macro (kbd "/ n ? <escape>"))
                (let ((visible (etaf-solitaire-test--help-visible-p runtime))
                      (editing (not (null (etaf-text-input-active-p runtime)))))
                  (should visible)
                  (should-not editing))
                (execute-kbd-macro (kbd "<escape>"))
                (etaf-solitaire-test--wait session)
                (let ((after (etaf-gamekit-observation session))
                      (focus (etaf-focused-host-ref runtime))
                      (selected (string-match-p
                                 "已选 A♣"
                                 (buffer-substring-no-properties (point-min) (point-max))))
                      (closed-again (etaf-help-close runtime)))
                  (should (equal before after))
                  (should (eq focus 'solitaire-help))
                  (should selected)
                  (should-not closed-again))))
            (etaf-dispatch-event runtime 'solitaire-foundation-2 'press)
            (etaf-solitaire-test--wait
             session (lambda () (= (etaf-gamekit-view session :action_count) 1))))
        (etaf-solitaire-close session)))))

(ert-deftest etaf-solitaire-help-survives-native-move-publication ()
  "A pending native move publishes beneath help without stealing its scope or focus."
  (save-window-excursion
    (let ((session (etaf-solitaire-open 11)))
      (unwind-protect
          (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
            (etaf-solitaire-test--wait session)
            (etaf-dispatch-event runtime 'solitaire-card-A♣ 'press)
            (etaf-dispatch-event runtime 'solitaire-foundation-2 'press)
            (etaf-focus runtime 'solitaire-help)
            (execute-kbd-macro (kbd "<f1>"))
            (let ((focus (etaf-focused-host-ref runtime))
                  (snapshot (etaf-help-data runtime)))
              (etaf-solitaire-test--wait
               session (lambda () (= (etaf-gamekit-view session :action_count) 1)))
              (let ((after-focus (etaf-focused-host-ref runtime))
                    (after-data (etaf-help-data runtime))
                    (visible (etaf-solitaire-test--help-visible-p runtime)))
                (should visible)
                (should (equal focus after-focus))
                (should (equal snapshot after-data))))
            (execute-kbd-macro (kbd "<escape> u"))
            (etaf-solitaire-test--wait
             session (lambda () (= (etaf-gamekit-view session :action_count) 0))))
        (etaf-solitaire-close session)))))

(provide 'etaf-solitaire-tests)
;;; etaf-solitaire-tests.el ends here
