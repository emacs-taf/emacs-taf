;;; -*- lexical-binding: t; -*-
;;; etaf-solitaire-gui-scenarios.el --- Native card table appearance and input
;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-solitaire)
(require 'emacs-gui-verifier)

(defun etaf-solitaire-gui--size (width rows)
  "Resize the dedicated frame toward WIDTH pixels and ROWS content lines."
  (let ((chrome (- (frame-pixel-height) (window-body-height nil t))))
    (set-frame-parameter nil 'fullscreen nil)
    (set-frame-size nil width (+ chrome (* rows (frame-char-height))) t)))

(defun etaf-solitaire-gui-run (directory)
  "Exercise native input, snapshots and both palettes in fresh DIRECTORY.
Run in an existing dedicated graphical frame without changing application
focus.  The owned deals, temporary snapshot and frame geometry are cleaned up
after success or failure; inspect the saved screenshots, because functional
assertions alone do not certify appearance."
  (unless (display-graphic-p) (error "A graphical frame is required"))
  (let ((frame-size (cons (frame-pixel-width) (frame-pixel-height)))
        (fullscreen (frame-parameter nil 'fullscreen))
        (file (make-temp-file "verdant-gui-"))
        session second runtime snapshot board-width card-metrics)
    (unwind-protect
        (cl-labels
            ((ready (&optional (target session))
               (and target (eq (etaf-gamekit-status target) 'ready)
                    (etaf-host-ref-size (etaf-runtime-for-buffer
                                         (etaf-gamekit-buffer target))
                                        'solitaire-board)))
             (text () (with-current-buffer (etaf-gamekit-buffer session)
                        (buffer-substring-no-properties (point-min) (point-max))))
             (press (ref) (etaf-focus runtime ref) (etaf-activate runtime))
             (action (id run settled &optional screenshot)
               (etaf-gui-verifier-action-create
                :id id :screenshot screenshot :settle-timeout 25
                :execute (lambda (_context) (funcall run))
                :settled-p (lambda (_context) (and (ready) (funcall settled)))))
             (key (id keys settled &optional screenshot)
               (action id (lambda ()
                            (switch-to-buffer (etaf-gamekit-buffer session))
                            (execute-kbd-macro (kbd keys)))
                       settled screenshot))
             (resize-actions (theme)
               (mapcar (lambda (spec)
                         (action (format "%s-%s" theme (car spec))
                                 (lambda () (etaf-solitaire-gui--size (cadr spec) (caddr spec)))
                                 (lambda () (= (cdr (etaf-runtime-viewport runtime))
                                               (window-body-height)))
                                 t))
                       '((wide 1200 44) (standard 1000 44) (narrow 620 40)
                         (short 1000 32) (minimum-clipping 420 24))))
             (open-second ()
               (setq second (etaf-solitaire-open 11))
               (let ((end (+ (float-time) 20)))
                 (while (and (< (float-time) end) (not (ready second)))
                   (accept-process-output nil 0.01)))
               ;; `etaf-solitaire-open' selects its own buffer; the verifier
               ;; requires this scenario's target buffer to stay selected.
               (switch-to-buffer (etaf-gamekit-buffer session))))
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "verdant" :claim "Native card table, keyboard play, snapshots and independent deals"
            :initialize
            (lambda (context)
              (let ((etaf-solitaire-appearance 'light)) (setq session (etaf-solitaire-open 11)))
              (setq runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
              (etaf-gui-verifier-context-select-buffer context (etaf-gamekit-buffer session))
              (message nil))
            :invariants
            (lambda (_context)
              (let ((current (etaf-host-ref-size runtime 'solitaire-board))
                    (card (etaf-host-ref-size runtime 'solitaire-card-A♣)))
                (when (and current (null board-width)) (setq board-width (car current)))
                (when (and card (null card-metrics)) (setq card-metrics card))
                (append
                 (list (etaf-gui-verifier-assert "The table keeps its fixed width"
                                                 (or (null current) (null board-width)
                                                     (= board-width (car current))))
                       (etaf-gui-verifier-assert
                        "Cards keep their intrinsic metrics while present"
                        (or (null card) (null card-metrics) (equal card-metrics card)))
                       (etaf-gui-verifier-assert "No backend or UI error"
                                                 (not (etaf-gamekit-last-error session))))
                 (etaf-gui-verifier-line-height-assertions (etaf-gamekit-buffer session)))))
            :actions
            (append
             (resize-actions "light")
             (list (key "dark-theme" "t" (lambda () (string-match-p "浅色" (text))) t))
             (resize-actions "dark")
             (list
              (action "restore-size" (lambda () (etaf-solitaire-gui--size 1000 44))
                      (lambda () (= (cdr (etaf-runtime-viewport runtime)) (window-body-height))))
              (key "hint-selects-a-source" "h" (lambda () (string-match-p "已选" (text))) t)
              (key "escape-clears-selection" "<escape>"
                   (lambda () (not (string-match-p "已选" (text)))))
              (key "browse-waste" "d" (lambda () (= (etaf-gamekit-view session :action_count) 0)))
              (action "play-ace-to-foundation"
                      (lambda () (press 'solitaire-card-A♣) (press 'solitaire-foundation-2))
                      (lambda () (= (etaf-gamekit-view session :action_count) 1)) t)
              (key "undo" "u" (lambda () (= (etaf-gamekit-view session :action_count) 0)))
              (key "redo" "y" (lambda () (= (etaf-gamekit-view session :action_count) 1)))
              (key "help" "<f1>" (lambda () (string-match-p "快捷键 · 只读" (text))) t)
              (key "close-help" "<escape>" (lambda () (not (string-match-p "快捷键 · 只读" (text)))))
              (action "save"
                      (lambda ()
                        (setq snapshot (etaf-gamekit-observation session))
                        (execute-kbd-macro (vconcat (kbd "C-s C-a C-k")
                                                    (string-to-vector file) (kbd "RET"))))
                      (lambda () (> (file-attribute-size (file-attributes file)) 0)))
              (key "new-deal" "n"
                   (lambda () (not (equal snapshot (etaf-gamekit-observation session)))))
              (action "load"
                      (lambda ()
                        (execute-kbd-macro (vconcat (kbd "C-o C-a C-k")
                                                    (string-to-vector file) (kbd "RET"))))
                      (lambda () (equal snapshot (etaf-gamekit-observation session))) t)
              (action "independent-instance" #'open-second
                      (lambda ()
                        (and (ready second)
                             (not (eq (etaf-gamekit-buffer second)
                                      (etaf-gamekit-buffer session))))))
              (action "second-instance-plays-alone"
                      (lambda ()
                        (let ((other-runtime (etaf-runtime-for-buffer
                                              (etaf-gamekit-buffer second))))
                          ;; Drive the second deal through its public runtime;
                          ;; the first deal's buffer stays the target.
                          (etaf-dispatch-event other-runtime 'solitaire-card-A♣ 'press)
                          (etaf-dispatch-event other-runtime 'solitaire-foundation-2 'press)))
                      (lambda ()
                        (and (= (etaf-gamekit-view second :action_count) 1)
                             (equal snapshot (etaf-gamekit-observation session)))) t)
              (key "theme-keeps-the-deal" "t"
                   (lambda () (equal snapshot (etaf-gamekit-observation session)))))))
           directory))
      (when (and second (buffer-live-p (etaf-gamekit-buffer second)))
        (etaf-solitaire-close second))
      (when session (etaf-solitaire-close session))
      (when (file-exists-p file) (delete-file file))
      (set-frame-size nil (car frame-size) (cdr frame-size) t)
      (set-frame-parameter nil 'fullscreen fullscreen))))

(provide 'etaf-solitaire-gui-scenarios)
;;; etaf-solitaire-gui-scenarios.el ends here
