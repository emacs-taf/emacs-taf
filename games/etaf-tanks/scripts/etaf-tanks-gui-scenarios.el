;;; -*- lexical-binding: t; -*-
;;; etaf-tanks-gui-scenarios.el --- Real battlefield appearance and native input
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-tanks)
(require 'emacs-gui-verifier)

(defconst etaf-tanks-gui--duel
  "name: 装甲对决\nenemies: 0 0 0 1\nmap:
@@@@EE@@@@@@\n@@@@EE@@@@@@\n@@@@..@@@@@@\n@@@@..@@@@@@\n@@@@..@@@@@@\n@@@@..@@@@@@
@@@@..@@@@@@\n@@@@..@@@@@@\n@@@@PP@@@@@@\n@@@@PP@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@
@@@@@@@@HH@@\n@@@@@@@@HH@@\n"
  "One armored enemy down a closed corridor, for a reachable stage tally.")

(defconst etaf-tanks-gui--sentry
  "name: 守卫\nenemies: 1 0 0 0\nmap:
EE@@@@@@@@@@\nEE@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@
@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@PP@@@@@@\n@@@@PP@@@@@@\n@@@@HH@@@@@@\n@@@@HH@@@@@@\n"
  "A player parked above the base, for a reachable defeat.")

(defun etaf-tanks-gui--size (width rows)
  "Resize the dedicated frame toward WIDTH pixels and ROWS content lines."
  (let ((chrome (- (frame-pixel-height) (window-body-height nil t))))
    (set-frame-parameter nil 'fullscreen nil)
    (set-frame-size nil width (+ chrome (* rows (frame-char-height))) t)))

(defun etaf-tanks-gui-run (directory)
  "Exercise every screen, input and both palettes; record evidence in DIRECTORY.
Run in an existing dedicated graphical frame.  Maps, progress and the
snapshot live in a temporary directory; the instance and frame geometry are
restored after success or failure.  Confirmations are answered with y under
`use-short-answers', which also suits configurations aliasing `yes-or-no-p'."
  (unless (display-graphic-p) (error "A graphical frame is required"))
  (let* ((size (cons (frame-pixel-width) (frame-pixel-height)))
         (fullscreen (frame-parameter nil 'fullscreen))
         (root (make-temp-file "iron-tide-gui-" t))
         (file (expand-file-name "battle.json" root))
         (etaf-tanks-map-directory (file-name-as-directory (expand-file-name "maps" root)))
         (etaf-tanks-progress-file (expand-file-name "progress.eld" root))
         (use-short-answers t)
         (messages (with-current-buffer (messages-buffer) (point-max)))
         session runtime saved frame-before)
    (unwind-protect
        (cl-labels
            ((ready () (and session (eq (etaf-gamekit-status session) 'ready)
                            (etaf-host-ref-size runtime 'tanks-board)))
             (view (key) (etaf-gamekit-view session key))
             (phase () (view :phase))
             (actor (key) (plist-get (view :actor) key))
             (text () (with-current-buffer (etaf-gamekit-buffer session)
                        (buffer-substring-no-properties (point-min) (point-max))))
             (timer-errors ()
               (with-current-buffer (messages-buffer)
                 (save-excursion (goto-char (min messages (point-max)))
                                 (re-search-forward "^Error running timer" nil t))))
             (keys (sequence)
               (switch-to-buffer (etaf-gamekit-buffer session))
               (execute-kbd-macro (if (stringp sequence) (kbd sequence) sequence)))
             (prompt (command)
               (keys (vconcat (kbd command) (kbd "C-a C-k") (string-to-vector file) (kbd "RET"))))
             (action (id run settled &optional screenshot)
               (etaf-gui-verifier-action-create
                :id id :screenshot screenshot :settle-timeout 20
                :execute (lambda (_context) (funcall run))
                :settled-p (lambda (_context) (and (ready) (funcall settled)))))
             (key (id sequence settled &optional screenshot)
               (action id (lambda () (keys sequence)) settled screenshot))
             (resize-actions (theme)
               (mapcar (lambda (spec)
                         (action (format "%s-%s" theme (car spec))
                                 (lambda () (etaf-tanks-gui--size (cadr spec) (caddr spec)))
                                 (lambda () (fits-viewport (eq (car spec) 'minimum-clipping))) t))
                       '((wide 1400 50) (standard 1100 44) (narrow 760 44)
                         (short 1100 32) (minimum-clipping 520 24))))
             ;; The Runtime follows the resized window, above the minimum the
             ;; whole table fits it without clipping, and Godot has redrawn
             ;; the battlefield for the board's new box.
             (fits-viewport (clipped)
               (let ((viewport (etaf-runtime-viewport runtime))
                     (bounds (etaf-host-ref-size runtime 'tanks-root)))
                 (and (= (cdr viewport) (window-body-height))
                      (<= (abs (- (car viewport) (window-body-width nil t))) (* 2 (frame-char-width)))
                      bounds (or clipped (<= (car bounds) (car viewport)))
                      (drawn))))
             ;; The published strips span the board Host to within a column.
             (drawn ()
               (let ((frame (view :frame)) (board (etaf-host-ref-size runtime 'tanks-board)))
                 (and frame board
                      (< -1 (- (car board) (/ (plist-get frame :width) (max 1 (round (frame-scale-factor)))))
                         (frame-char-width)))))
             (begin (map)
               (etaf-gamekit-action session "begin" (list :map map :stage 1 :difficulty "easy" :seed 5))
               (let ((end (+ (float-time) 6)))
                 (while (and (< (float-time) end) (not (and (ready) (equal (phase) "play"))))
                   (accept-process-output nil 0.01))))
             (fight ()
               (begin etaf-tanks-gui--duel)
               (let ((end (+ (float-time) 20)))
                 (while (and (< (float-time) end) (not (member (phase) '("cleared" "over"))))
                   (when (and (ready) (eq t (actor :can_fire))) (keys "f"))
                   (accept-process-output nil 0.05)))))
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "iron-tide" :claim "Stage select, battle, editor, dialogs, dual themes and resize"
            :initialize
            (lambda (context)
              (let ((etaf-tanks-appearance 'light)) (setq session (etaf-tanks-open)))
              (setq runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
              (etaf-gui-verifier-context-select-buffer context (etaf-gamekit-buffer session))
              (message nil))
            :invariants
            (lambda (_context)
              (append
               (list (etaf-gui-verifier-assert "No backend or UI error" (not (etaf-gamekit-last-error session)))
                     (etaf-gui-verifier-assert "No failed publication" (not (timer-errors))))
               (etaf-gui-verifier-line-height-assertions (etaf-gamekit-buffer session))))
            :actions
            (append
             (resize-actions "light")
             ;; The minimum-size case deliberately clips the header; restore
             ;; its controls before asserting on the theme button's label.
             (list (action "restore-before-theme" (lambda () (etaf-tanks-gui--size 1100 44))
                           (lambda () (fits-viewport nil)))
                   (key "dark-theme" "t" (lambda () (string-match-p "浅色 · t" (text))) t))
             (resize-actions "dark")
             (list
              (action "restore-size" (lambda () (etaf-tanks-gui--size 1100 44))
                      (lambda () (fits-viewport nil)))
              (key "start" "g" (lambda () (and (equal (phase) "play") (drawn))) t)
              (key "drive" "<right>" (lambda () (equal (actor :facing) "e")))
              (key "aim-north" "S-<up>" (lambda () (equal (actor :facing) "n")))
              (key "fire" "f" (lambda () (> (actor :shots) 0)) t)
              (key "pause" "p" (lambda () (eq t (view :paused))) t)
              (key "resume" "p" (lambda () (eq :false (view :paused))))
              (action "pause-on-leave"
                      (lambda ()
                        (let ((other (generate-new-buffer " *tank focus acceptance*")) (end (+ (float-time) 4)))
                          (unwind-protect
                              (progn
                                (switch-to-buffer other) (redisplay t)
                                (while (and (< (float-time) end) (not (eq t (view :paused))))
                                  (accept-process-output nil 0.01)))
                            (switch-to-buffer (etaf-gamekit-buffer session)) (kill-buffer other))))
                      (lambda () (eq t (view :paused))))
              (key "resume-before-help" "p" (lambda () (eq :false (view :paused))))
              (key "help" "?" (lambda () (and (eq t (view :paused))
                                                (string-match-p "搜索快捷键或操作" (text)))) t)
              (key "close-help" "<escape>" (lambda () (and (eq t (view :paused))
                                                           (not (string-match-p "搜索快捷键或操作" (text))))))
              (key "help-f1" "<f1>" (lambda () (string-match-p "搜索快捷键或操作" (text))))
              (key "search-help" "/ f <escape>"
                   (lambda () (and (eq t (view :paused))
                                   (not (etaf-text-input-active-p runtime))
                                   (string-match-p "快捷键" (text)))))
              (key "close-searched-help" "<escape>"
                   (lambda () (and (eq t (view :paused))
                                   (not (string-match-p "快捷键" (text))))))
              (key "settings" "s" (lambda () (string-match-p "游戏速度" (text))) t)
              (key "close-settings" "<escape>" (lambda () (not (string-match-p "游戏速度" (text)))))
              (action "save"
                      (lambda ()
                        (setq saved (list (actor :x) (actor :y) (actor :facing)))
                        (prompt "C-s"))
                      (lambda () (and (file-exists-p file) (> (file-attribute-size (file-attributes file)) 0))))
              (key "restart" "r" (lambda () (and (member (phase) '("intro" "play")) (= (actor :shots) 0)
                                                (not (equal (list (actor :x) (actor :y) (actor :facing)) saved)))))
              (action "load"
                      (lambda ()
                        (prompt "C-o"))
                      (lambda () (and (eq t (view :paused)) (equal (list (actor :x) (actor :y) (actor :facing)) saved))) t)
              (key "leave" "m" (lambda () (equal (phase) "menu")))
              (action "final-stage" (lambda () (etaf-focus runtime 'tanks-stage-20))
                      (lambda () (and (equal (phase) "menu") (equal (view :size) '(40 30)) (drawn))) t)
              (key "final-battle" "g" (lambda () (and (equal (phase) "play") (equal (view :size) '(40 30)) (drawn))) t)
              (key "pause-final" "p" (lambda () (eq t (view :paused))))
              (key "leave-final" "m" (lambda () (equal (phase) "menu")))
              (key "editor" "e" (lambda () (equal (phase) "edit")) t)
              ;; Arrows draw while they are held; Shift with an arrow only moves.
              (key "arrow-draw" "S-<right> S-<right> S-<right> S-<right> <right> <right>"
                   (lambda ()
                     (let ((cursor (view :editor)))
                       (and (eql (plist-get cursor :x) 6) (eql (plist-get cursor :y) 0)
                            (string-match-p "地图编辑 · 未保存" (text))))) t)
              (key "editor-home" "S-<left> S-<left> S-<left> S-<left> S-<left> S-<left>"
                   (lambda ()
                     (let ((cursor (view :editor)))
                       (and (eql (plist-get cursor :x) 0) (eql (plist-get cursor :y) 0)))))
              (key "locate-paint" "S-<right> S-<right> S-<down> 3"
                   (lambda () (let ((cursor (view :editor)))
                                (and (eql (plist-get cursor :x) 2) (eql (plist-get cursor :y) 1)))))
              (action "paint-button"
                      (lambda ()
                        (setq frame-before (plist-get (view :frame) :id))
                        (etaf-dispatch-event runtime 'tanks-map-paint 'press))
                      (lambda () (> (plist-get (view :frame) :id) frame-before)) t)
              (action "undo-paint"
                      (lambda ()
                        (setq frame-before (plist-get (view :frame) :id))
                        (etaf-dispatch-event runtime 'tanks-map-undo 'press))
                      (lambda () (> (plist-get (view :frame) :id) frame-before)) t)
              (action "paint-key"
                      (lambda () (setq frame-before (plist-get (view :frame) :id)) (keys "f"))
                      (lambda () (> (plist-get (view :frame) :id) frame-before)) t)
              (action "pen-off" (lambda () (etaf-dispatch-event runtime 'tanks-pen 'press))
                      (lambda () (string-match-p "绘制：关" (text))) t)
              (action "pen-on" (lambda () (etaf-dispatch-event runtime 'tanks-pen 'press))
                      (lambda () (string-match-p "绘制：开" (text))) t)
              (key "discard-edit" "m y" (lambda () (equal (phase) "menu")))
              (action "stage-tally" #'fight (lambda () (equal (phase) "cleared")) t)
              (action "defeat"
                      (lambda () (begin etaf-tanks-gui--sentry) (keys "S-<down> f"))
                      (lambda () (equal (phase) "over")) t))))
           directory))
      (when session (etaf-tanks-close session))
      (delete-directory root t)
      (set-frame-size nil (car size) (cdr size) t)
      (set-frame-parameter nil 'fullscreen fullscreen))))

(provide 'etaf-tanks-gui-scenarios)
;;; etaf-tanks-gui-scenarios.el ends here
