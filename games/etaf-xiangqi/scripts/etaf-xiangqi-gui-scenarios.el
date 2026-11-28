;;; -*- lexical-binding: t; -*-
;;; etaf-xiangqi-gui-scenarios.el --- Native board appearance and input acceptance
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-xiangqi)
(require 'emacs-gui-verifier)

(defun etaf-xiangqi-gui--size (width rows)
  "Set the existing verification frame to WIDTH pixels and ROWS content lines."
  (let ((chrome (- (frame-pixel-height) (window-body-height nil t))))
    (set-frame-parameter nil 'fullscreen nil)
    (set-frame-size nil width (+ chrome (* rows (frame-char-height))) t)))

(defun etaf-xiangqi-gui-run (directory)
  "Save board appearance and native keyboard acceptance to fresh DIRECTORY.
Use a dedicated, already running graphical frame without changing application
focus. Dispose the owned match and restore frame geometry even after failure."
  (unless (display-graphic-p) (error "A graphical frame is required"))
  (let ((size (cons (frame-pixel-width) (frame-pixel-height)))
        (fullscreen (frame-parameter nil 'fullscreen))
        (etaf-animation-enabled t) (etaf-animation-paused nil)
        session runtime board before focus flight-at)
    (unwind-protect
        (cl-labels
            ((ready (_context)
               (and session (eq (etaf-gamekit-status session) 'ready)
                    (etaf-host-ref-size runtime 'xiangqi-cell-6-4)
                    (not (plist-get (etaf-runtime-host-props-for runtime 'xiangqi-new) :disabled))))
             (text ()
               (with-current-buffer (etaf-gamekit-buffer session)
                 (buffer-substring-no-properties (point-min) (point-max))))
             (geometry-actions (theme)
               (mapcar
                (lambda (spec)
                  (etaf-gui-verifier-action-create
                   :id (format "%s-%s" theme (car spec)) :screenshot t
                   :execute (lambda (_context) (etaf-xiangqi-gui--size (cadr spec) (caddr spec)))
                   :settled-p
                   (lambda (context)
                     (and (ready context)
                          (= (cdr (etaf-runtime-viewport runtime)) (window-body-height))))))
                '((wide 1200 46) (standard 900 44) (narrow 550 42)
                  (short 1000 34) (minimum-clipping 320 20))))
             (key-action (id keys predicate &optional screenshot)
               (etaf-gui-verifier-action-create
                :id id :screenshot screenshot
                :execute (lambda (_context)
                           (switch-to-buffer (etaf-gamekit-buffer session))
                           (execute-kbd-macro (kbd keys)))
                :settled-p (lambda (context) (and (ready context) (funcall predicate))))))
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "xiangqi-board" :claim "Vector appearance and native input across both themes and viewport sizes"
            :initialize
            (lambda (context)
              (let ((etaf-xiangqi-appearance 'light)
                    (etaf-xiangqi-opponent 'hot-seat))
                (setq session (etaf-xiangqi-open 11)))
              (setq runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
              (etaf-gui-verifier-context-select-buffer context (etaf-gamekit-buffer session))
              (message nil))
            :invariants
            (lambda (_context)
              (let ((current (etaf-host-ref-size runtime 'xiangqi-board)))
                (unless board (setq board current))
                (append
                 (list (etaf-gui-verifier-assert "Board cells keep their intrinsic geometry" (equal board current))
                       (etaf-gui-verifier-assert "No game or transport rejection" (not (etaf-gamekit-last-error session)))
                       (etaf-gui-verifier-assert
                        "A restored wide window shows the whole table"
                        (let ((root (etaf-host-ref-size runtime 'xiangqi-root))
                              (viewport (etaf-runtime-viewport runtime)))
                          (or (null root) (/= (car viewport) (window-body-width nil t))
                              (< (window-body-width nil t) (car root))
                              (= (window-hscroll) 0)))))
                 (etaf-gui-verifier-line-height-assertions (etaf-gamekit-buffer session)))))
            :actions
            (append
             (geometry-actions "light")
             (list
              (etaf-gui-verifier-action-create
               :id "select-stone" :screenshot t
               :execute (lambda (_context)
                          (etaf-xiangqi-gui--size 900 44)
                          (etaf-focus runtime 'xiangqi-cell-6-4)
                          (execute-kbd-macro (kbd "RET"))
                          (setq before (etaf-gamekit-observation session)
                                focus (etaf-focused-host-ref runtime)))
               :settled-p (lambda (context) (and (ready context) (string-match-p "已选 红兵" (text)))))
              (etaf-gui-verifier-action-create
               :id "dark-preserves-selection" :screenshot t
               :execute (lambda (_context) (execute-kbd-macro (kbd "t")))
               :settled-p (lambda (context) (and (ready context) (string-match-p "浅色" (text))))
               :assertions
               (lambda (_context)
                 (list (etaf-gui-verifier-assert "Theme switch preserves the native match" (equal before (etaf-gamekit-observation session)))
                       (etaf-gui-verifier-assert "Theme switch preserves keyboard focus" (equal focus (etaf-focused-host-ref runtime)))
                       (etaf-gui-verifier-assert "Theme switch preserves selection" (string-match-p "已选 红兵" (text)))))))
             (geometry-actions "dark")
             (list
              (etaf-gui-verifier-action-create
               :id "restore-for-input"
               :execute (lambda (_context) (etaf-xiangqi-gui--size 900 44)) :settled-p #'ready)
              (key-action "keyboard-move" "<up> RET"
                          (lambda () (and (= (etaf-gamekit-view session :action_count) 1)
                                          (= (etaf-gamekit-view session :player) 1))) t)
              (key-action "undo" "u" (lambda () (= (etaf-gamekit-view session :action_count) 0)))
              (key-action "redo" "y" (lambda () (= (etaf-gamekit-view session :action_count) 1)))
              (key-action "help" "<f1>" (lambda () (string-match-p "快捷键 · 只读" (text))) t)
              (key-action "close-help" "<escape>" (lambda () (not (string-match-p "快捷键 · 只读" (text)))))
              (key-action "new-match" "n" (lambda () (= (etaf-gamekit-view session :action_count) 0)))
              (etaf-gui-verifier-action-create
               :id "legal-moves" :screenshot t
               :execute (lambda (_context) (etaf-focus runtime 'xiangqi-show-moves) (etaf-activate runtime))
               :settled-p (lambda (context) (and (ready context) (string-match-p "可走位置" (text)))))
              (key-action "close-legal-moves" "<escape>" (lambda () (not (string-match-p "可走位置" (text)))))
              (key-action "opponent-settings" "o" (lambda () (string-match-p "对局设置" (text))) t)
              (etaf-gui-verifier-action-create
               :id "computer-in-flight-dark" :screenshot t
               :execute (lambda (_context)
                          (etaf-focus runtime 'xiangqi-opponent-computer-red)
                          (etaf-activate runtime)
                          (execute-kbd-macro (kbd "<escape>")))
               :settled-p (lambda (_context)
                            (when (string-match-p "电脑落子中" (text))
                              (unless flight-at (setq flight-at (float-time)))
                              (when (> (- (float-time) flight-at) 0.07)
                                (setq etaf-animation-paused t)
                                t))))
              (etaf-gui-verifier-action-create
               :id "computer-in-flight-light" :screenshot t
               :execute (lambda (_context) (execute-kbd-macro (kbd "t")))
               :settled-p (lambda (_context)
                            (and etaf-animation-paused (string-match-p "暗色" (text))
                                 (string-match-p "电脑落子中" (text)))))
              (etaf-gui-verifier-action-create
               :id "computer-takes-red" :screenshot t
               :execute (lambda (_context) (setq etaf-animation-paused nil))
               :settled-p (lambda (context)
                            (and (ready context)
                                 (= (etaf-gamekit-view session :action_count) 1)
                                 (= (etaf-gamekit-view session :player) 1)))
               :assertions
               (lambda (_context)
                 (list (etaf-gui-verifier-assert
                        "The computer answers by itself when it owns the side to move"
                        (and (= 1 (etaf-gamekit-view session :action_count))
                             (= 1 (etaf-gamekit-view session :current_player))
                             (string-match-p "轮到你走棋" (text)))))))
              (key-action "opponent-settings-light" "o"
                          (lambda () (string-match-p "对局设置" (text))) t)
              (key-action "close-opponent-settings-light" "<escape>"
                          (lambda () (not (string-match-p "对局设置" (text))))))))
           directory))
      (when session (etaf-xiangqi-close session))
      (set-frame-size nil (car size) (cdr size) t)
      (set-frame-parameter nil 'fullscreen fullscreen))))

(provide 'etaf-xiangqi-gui-scenarios)
;;; etaf-xiangqi-gui-scenarios.el ends here
