;;; -*- lexical-binding: t; -*-
;;; etaf-bili-gui-scenarios.el --- Catalog, Watch View and real-library acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; In an isolated graphical frame with the user's full configuration, load
;; ETAF's scripts/emacs-gui-verifier.el, then call (etaf-bili-gui-run DIR).
;; Native focus/RET activates the actual catalog controls and exercises both
;; Gallery View and Watch View across viewports and themes.

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
          (when (and (memq type '(jpeg png webp)) data (not (gethash data seen)))
            (puthash data t seen)
            (let* ((source (image-size (create-image data type t :scale 1) t))
                   (shown (image-size image t))
                   (expected (/ (* (float (car shown)) (cdr source)) (car source))))
              (unless (<= (abs (- (cdr shown) expected)) 1.01) (setq valid nil)))))
        (setq position (or (next-single-property-change position 'display nil (point-max)) (point-max))))
      (and valid (> (hash-table-count seen) 0)))))

(defun etaf-bili-gui--has-jpeg-frame ()
  "Return non-nil when `*Bili*' currently displays a live decoded video frame."
  (with-current-buffer "*Bili*"
    (let ((pos (point-min)) (found nil))
      (while (and (not found) (< pos (point-max)))
        (let* ((img (etaf-bili-gui--image (get-text-property pos 'display)))
               (type (and img (plist-get (cdr img) :type))))
          (when (memq type '(jpeg pbm ppm tiff canvas)) (setq found t)))
        (setq pos (or (next-single-property-change pos 'display nil (point-max)) (point-max))))
      found)))

(defun etaf-bili-gui--cover-count ()
  "Return the number of distinct decoded cover images currently visible in `*Bili*'."
  (with-current-buffer "*Bili*"
    (let ((pos (point-min)) (seen (make-hash-table :test #'eq)))
      (while (< pos (point-max))
        (let* ((img (etaf-bili-gui--image (get-text-property pos 'display)))
               (type (and img (plist-get (cdr img) :type)))
               (data (and img (plist-get (cdr img) :data))))
          (when (and (memq type '(jpeg png webp)) data)
            (puthash data t seen)))
        (setq pos (or (next-single-property-change pos 'display nil (point-max)) (point-max))))
      (hash-table-count seen))))

(defun etaf-bili-gui-run (directory)
  "Run real-library Gallery & Watch View checks, saving evidence to DIRECTORY."
  (let* ((tmp-dir (make-temp-file "etaf-bili-gui-store-" t))
         (etaf-bili-store-file (expand-file-name "state.sqlite3" tmp-dir))
         (actions nil))
    ;; Keep automated GUI run muted so real live playback does not blast speakers.
    (etaf-bili-store-pref-put 'audio nil)
    (cl-labels
        ((step (name execute settled &optional screenshot)
           (push (etaf-gui-verifier-action-create
                  :id name :settle-timeout 35
                  :execute (lambda (_context) (funcall execute))
                  :settled-p (lambda (_context) (and (funcall settled) t))
                  :assertions (lambda (_context)
                                (list (etaf-gui-verifier-assert name (and (funcall settled) t))))
                  :screenshot screenshot) actions))
         (ready () (and (etaf-bili-gui--cards)
                        (not (string-match-p "加载中" (etaf-bili-gui--text)))))
         (in-watch () (and (string-match-p "← 返回" (etaf-bili-gui--text))
                           (not (string-match-p "正在获取播放地址" (etaf-bili-gui--text)))))
         (resize (columns rows)
           (when (frame-parameter (selected-frame) 'fullscreen)
             (set-frame-parameter (selected-frame) 'fullscreen nil))
           (set-frame-size (selected-frame) columns rows))
         (near-width (columns) (<= (abs (- (frame-width) columns)) 3))
         (layout (columns)
           (and (near-width columns) (ready)
                (let* ((rt (etaf-bili-gui--runtime))
                       (shell (etaf-host-ref-size rt 'bili-shell))
                       (viewport (etaf-runtime-window-viewport rt)))
                  (<= (car shell) (car viewport))))))
      (step "popular-covers" #'ignore
            (lambda ()
              (and (ready) (etaf-bili-gui--aspect-check)
                   (>= (etaf-bili-gui--cover-count) 4)
                   (not (null (buffer-local-value 'mode-line-format (get-buffer "*Bili*"))))))
            t)
      (step "wheel-scroll" (lambda ()
                             (switch-to-buffer "*Bili*")
                             (etaf-focus (etaf-bili-gui--runtime) 'bili-card-0)
                             (execute-kbd-macro (vector (list 'wheel-down (posn-at-point) 1))))
            (lambda () (> (etaf-scroll-offset (etaf-bili-gui--runtime) 'bili-gallery) 0)) t)
      (step "scroll-top" (lambda () (etaf-scroll-to (etaf-bili-gui--runtime) 'bili-gallery 'start))
            (lambda () (memq 'bili-card-0 (etaf-bili-gui--cards))))
      (step "details" (lambda () (etaf-bili-gui--press 'bili-details))
            (lambda () (string-match-p "视频详情" (etaf-bili-gui--text))) t)
      (step "close-details" (lambda () (execute-kbd-macro (kbd "<escape>")))
            (lambda () (not (string-match-p "视频详情" (etaf-bili-gui--text)))))
      (step "ranking" (lambda () (etaf-bili-gui--press 'bili-ranking))
            (lambda () (and (ready) (string-match-p "排行榜 ·" (etaf-bili-gui--text))
                            (string-match-p "分区：" (etaf-bili-gui--text)))) t)
      (step "watch-wide-dark" (lambda ()
                                (resize 160 44)
                                (switch-to-buffer "*Bili*")
                                (etaf-bili-play))
            (lambda ()
              (let ((txt (etaf-bili-gui--text)))
                (and (in-watch)
                     (string-match-p "选集" txt)
                     (etaf-bili-gui--has-jpeg-frame)
                     (not (string-match-p "缓冲中" txt))
                     (not (string-match-p "00:00" txt)))))
            t)
      (step "watch-quality-dialog" (lambda () (etaf-bili-watch-quality-menu))
            (lambda () (string-match-p "选择画质与线路" (etaf-bili-gui--text))) t)
      (step "watch-quality-close" (lambda () (etaf-bili-watch-escape))
            (lambda () (and (in-watch) (not (string-match-p "选择画质与线路" (etaf-bili-gui--text))))))
      (step "watch-theater" (lambda () (etaf-bili-watch-toggle-theater))
            (lambda () (and (in-watch) (string-match-p "侧栏 (i)" (etaf-bili-gui--text)))) t)
      (step "watch-theater-off" (lambda () (etaf-bili-watch-toggle-theater))
            (lambda () (and (in-watch) (string-match-p "选集" (etaf-bili-gui--text)))))
      (step "watch-wide-light" (lambda () (etaf-bili-toggle-theme))
            (lambda () (and (in-watch) (eq etaf-bili-theme-mode 'light))) t)
      (step "watch-narrow" (lambda () (resize 84 32))
            (lambda () (and (near-width 84) (in-watch)
                            (string-match-p "侧栏 (i)" (etaf-bili-gui--text))
                            (etaf-bili-gui--has-jpeg-frame)))
            t)
      (step "watch-short" (lambda () (resize 140 28))
            (lambda () (and (near-width 140) (in-watch)
                            (string-match-p "选集" (etaf-bili-gui--text))
                            (etaf-bili-gui--has-jpeg-frame)))
            t)
      (step "watch-back-gallery" (lambda ()
                                   (etaf-bili-watch-back)
                                   (resize 150 42))
            (lambda () (and (near-width 150) (ready))) t)
      (step "gallery-light-wide" #'ignore (lambda () (layout 150)) t)
      (step "gallery-dark-wide" (lambda () (etaf-bili-toggle-theme))
            (lambda () (and (eq etaf-bili-theme-mode 'dark) (layout 150))) t)
      (unwind-protect
          (etaf-gui-verifier-run
           (etaf-gui-verifier-scenario-create
            :name "bili-gallery-and-watch"
            :claim "Real covers, live decoded video frames, mode-line preservation, Watch View split/theater/quality/narrow/short layouts and both palettes"
            :initialize (lambda (context)
                          (setq etaf-bili-theme-mode 'dark)
                          (resize 150 42)
                          (setf (etaf-gui-verifier-context-target-buffer context) (etaf-bili-open)))
            :actions (nreverse actions)
            :invariants (lambda (_context) (etaf-gui-verifier-line-height-assertions (get-buffer "*Bili*")))
            :completion (lambda (_context) t))
           directory)
        (ignore-errors (etaf-bili-close))
        (ignore-errors (delete-directory tmp-dir t))))))

(provide 'etaf-bili-gui-scenarios)
