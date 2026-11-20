;;; -*- lexical-binding: t; -*-
;;; etaf-bili-gui-scenarios.el --- Catalog and real-library acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; In an isolated graphical frame with the user's full configuration, load
;; ETAF's scripts/emacs-gui-verifier.el, then call (etaf-bili-gui-run DIR).
;; Native focus/RET activates the actual catalog controls.  Captures include
;; the title bar; this runner never changes decoration or foreground focus.

;;; Code:
(require 'cl-lib)
(require 'etaf-bili)
(require 'etaf-ui)
(require 'emacs-gui-verifier)

(defun etaf-bili-gui--text ()
  "Return the current application text without properties."
  (with-current-buffer "*Bili*" (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-bili-gui--runtime ()
  "Return the displayed application's public runtime."
  (etaf-runtime-for-buffer "*Bili*"))

(defun etaf-bili-gui--cards ()
  "Return committed card references."
  (cl-loop for (_ . props) in (etaf-runtime-host-props-entries (etaf-bili-gui--runtime))
           for ref = (plist-get props :ref)
           when (and (symbolp ref) (string-prefix-p "bili-card-" (symbol-name ref)))
           collect ref))

(defun etaf-bili-gui--press (ref)
  "Focus REF and activate it through the real Return key."
  (switch-to-buffer "*Bili*")
  (etaf-focus (etaf-bili-gui--runtime) ref)
  (execute-kbd-macro (kbd "RET")))

(defun etaf-bili-gui--image (value)
  "Find an Emacs image descriptor inside public display VALUE."
  (cond ((not (consp value)) nil)
        ((eq (car value) 'image) value)
        (t (cl-some #'etaf-bili-gui--image value))))

(defun etaf-bili-gui--aspect-check ()
  "Check that each displayed cover has its source's aspect, within one pixel."
  (with-current-buffer "*Bili*"
    (let ((position (point-min)) (seen (make-hash-table :test #'eq)) (valid t))
      (while (< position (point-max))
        (let* ((image (etaf-bili-gui--image (get-text-property position 'display)))
               (type (and image (plist-get (cdr image) :type)))
               (data (and image (plist-get (cdr image) :data))))
          ;; Published image descriptors own bytes, not their former cache
          ;; path.  Compare the public displayed image to the same bytes at
          ;; their native dimensions; exclude the catalog's SVG icons.
          (when (and (memq type '(jpeg png webp)) data (not (gethash data seen)))
            (puthash data t seen)
            (let* ((source (image-size (create-image data type t :scale 1) t))
                   (shown (image-size image t))
                   (expected (/ (* (float (car shown)) (cdr source)) (car source))))
              (unless (<= (abs (- (cdr shown) expected)) 1.01) (setq valid nil)))))
        (setq position (or (next-single-property-change position 'display nil (point-max)) (point-max))))
      (and valid (> (hash-table-count seen) 0)))))

(defun etaf-bili-gui-run (directory)
  "Run real-library controls and viewport checks, saving evidence to DIRECTORY."
  (let (actions)
    (cl-labels
        ((step (name execute settled &optional screenshot)
           (push (etaf-gui-verifier-action-create
                  :id name :settle-timeout 40
                  :execute (lambda (_context) (funcall execute))
                  :settled-p (lambda (_context) (and (funcall settled) t))
                  :assertions (lambda (_context)
                                (list (etaf-gui-verifier-assert name (and (funcall settled) t))))
                  :screenshot screenshot) actions))
         (ready () (and (etaf-bili-gui--cards)
                        (not (string-match-p "加载中" (etaf-bili-gui--text)))))
         (resize (columns rows)
           (set-frame-size (selected-frame) columns rows))
         (layout (columns)
           (and (= columns (frame-width)) (ready)
                (let* ((rt (etaf-bili-gui--runtime))
                       (shell (etaf-host-ref-size rt 'bili-shell))
                       (viewport (etaf-runtime-window-viewport rt)))
                  (<= (car shell) (car viewport))))))
      (step "popular-covers" #'ignore (lambda () (and (ready) (etaf-bili-gui--aspect-check))) t)
      (step "wheel-scroll" (lambda ()
                              (switch-to-buffer "*Bili*")
                              (etaf-focus (etaf-bili-gui--runtime) 'bili-card-0)
                              (execute-kbd-macro (vector (list 'wheel-down (posn-at-point) 1))))
            (lambda () (> (etaf-scroll-offset (etaf-bili-gui--runtime) 'bili-gallery) 0)) t)
      (step "scroll-end" (lambda () (etaf-scroll-to (etaf-bili-gui--runtime) 'bili-gallery 'end))
            (lambda () (and (memq 'bili-card-19 (etaf-bili-gui--cards))
                             (not (memq 'bili-card-0 (etaf-bili-gui--cards))))) t)
      (step "keyboard-reveal" (lambda () (etaf-bili-next))
            (lambda () (and (eq (etaf-focused-host-ref (etaf-bili-gui--runtime)) 'bili-card-1)
                             (= 0 (etaf-scroll-offset (etaf-bili-gui--runtime) 'bili-gallery)))))
      (step "scroll-top" (lambda () (etaf-scroll-to (etaf-bili-gui--runtime) 'bili-gallery 'start))
            (lambda () (memq 'bili-card-0 (etaf-bili-gui--cards))))
      (step "details" (lambda () (etaf-bili-gui--press 'bili-details))
            (lambda () (string-match-p "视频详情" (etaf-bili-gui--text))) t)
      (step "close-details" (lambda () (execute-kbd-macro (kbd "<escape>")))
            (lambda () (not (string-match-p "视频详情" (etaf-bili-gui--text)))))
      (step "search" (lambda ()
                       (switch-to-buffer "*Bili*")
                       (execute-kbd-macro (kbd "/"))
                       (execute-kbd-macro (vconcat "Emacs 配置"))
                       (execute-kbd-macro (kbd "RET")))
            (lambda () (and (ready) (string-match-p "搜索 Emacs 配置" (etaf-bili-gui--text)))) t)
      (step "ranking" (lambda () (etaf-bili-gui--press 'bili-ranking))
            (lambda () (and (ready) (string-match-p "排行榜 ·" (etaf-bili-gui--text)))) t)
      (step "light" (lambda () (etaf-bili-gui--press 'bili-theme))
            (lambda () (eq etaf-bili-theme-mode 'light)) t)
      (dolist (shape '((110 36) (80 32) (150 30) (180 48)))
        (let ((columns (car shape)) (rows (cadr shape)))
          (step (format "viewport-%dx%d" columns rows)
                (lambda () (resize columns rows))
                (lambda () (layout columns)) t)))
      (step "dark" (lambda () (etaf-bili-gui--press 'bili-theme))
            (lambda () (eq etaf-bili-theme-mode 'dark)) t)
      (etaf-gui-verifier-run
       (etaf-gui-verifier-scenario-create
        :name "bili-catalog" :claim "Real covers, wheel scrolling, keyboard reveal, catalog controls and both palettes across four viewports"
        :initialize (lambda (context)
                      (setq etaf-bili-theme-mode 'dark)
                      (setf (etaf-gui-verifier-context-target-buffer context) (etaf-bili-open)))
        :actions (nreverse actions)
        :invariants (lambda (_context) (etaf-gui-verifier-line-height-assertions (get-buffer "*Bili*")))
        :completion (lambda (_context) t))
       directory))))

(provide 'etaf-bili-gui-scenarios)
