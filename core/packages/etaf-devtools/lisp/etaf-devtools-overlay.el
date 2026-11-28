;;; etaf-devtools-overlay.el --- Zero-distortion target buffer overlays -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Renders read-only selection highlights and Highlight Updates flash overlays
;; directly over a target ETAF buffer using exact per-row buffer spans from
;; `etaf-runtime-inspect-host' and `:ranges' from `etaf-runtime-update-report'.
;; Never modifies buffer text, never invokes Ebox flush, and never advances the
;; inspected Runtime's revision.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-devtools-core)

(declare-function etaf-posframe-show "etaf-posframe" (view &rest options))
(declare-function etaf-posframe-hide "etaf-posframe" (&optional panel))
(declare-function etaf-posframe-live-p "etaf-posframe" (panel))
(declare-function etaf-posframe-panel-frame "etaf-posframe" (panel))
(declare-function etaf-devtools--register-own-buffer "etaf-devtools-target" (buffer))
(defvar etaf-devtools--creating-own-surface)

(defvar etaf-devtools--selection-overlays nil
  "Active Emacs overlays highlighting the currently inspected Host.")

(defvar etaf-devtools--badge-panel nil
  "Active floating `etaf-posframe' badge showing inspected Host dimensions.")

(defvar etaf-devtools--flash-entries nil
  "List of `(EXPIRE-TIME . OVERLAY)' entries for Highlight Updates.")

(defvar etaf-devtools--flash-timer nil
  "Single reusable timer expiring active Highlight Updates overlays.")

(defvar etaf-devtools--flash-last-at (make-hash-table :test #'eq :weakness 'key)
  "Last flash timestamp per buffer for high-FPS throttling.")

(defun etaf-devtools--posframe-ready-p ()
  "Return non-nil when `etaf-posframe' can show a floating badge."
  (and etaf-devtools-use-posframe
       (display-graphic-p)
       (ignore-errors (require 'etaf-posframe nil t))
       (fboundp 'etaf-posframe-show)))

(defun etaf-devtools--overlay-clear-selection ()
  "Remove all selection highlight overlays and hide any floating badge."
  (dolist (ov etaf-devtools--selection-overlays)
    (when (overlayp ov)
      (delete-overlay ov)))
  (setq etaf-devtools--selection-overlays nil)
  (when (and etaf-devtools--badge-panel
             (fboundp 'etaf-posframe-hide))
    (ignore-errors (etaf-posframe-hide etaf-devtools--badge-panel)))
  (setq etaf-devtools--badge-panel nil))

(defun etaf-devtools--badge-view (label size-str pal)
  "Build compact 1-row ETAF View for the floating Host dimension badge."
  (etaf-view
   (row :padding '((lh 0) (ch 1))
        :background-color (plist-get pal :surface2)
        :item-gap '(ch 1)
        (text :color (plist-get pal :accent) :font-weight 'bold (expr label))
        (text :color (plist-get pal :ok) :font-weight 'bold (expr size-str)))))

(defun etaf-devtools--show-badge (buf label size-str pal)
  "Display compact floating badge for BUF when graphical posframe is ready."
  (when (and (buffer-live-p buf)
             (get-buffer-window buf t)
             (etaf-devtools--posframe-ready-p))
    (condition-case nil
        (let ((win (get-buffer-window buf t))
              (etaf-devtools--creating-own-surface t))
          (with-selected-window win
            (setq etaf-devtools--badge-panel
                  (etaf-posframe-show
                   (etaf-devtools--badge-view label size-str pal)
                   :key 'etaf-devtools-badge
                   :at 'window-top-right
                   :width (+ (string-width label) (string-width size-str) 5)
                   :height 1
                   :focusable nil
                   :auto-hide nil
                   :theme 'auto))
            (when-let* ((pfr (and etaf-devtools--badge-panel
                                  (fboundp 'etaf-posframe-panel-frame)
                                  (etaf-posframe-panel-frame etaf-devtools--badge-panel)))
                        ((frame-live-p pfr))
                        (pbuf (window-buffer (frame-root-window pfr))))
              (etaf-devtools--register-own-buffer pbuf))))
      (error nil))))

(defun etaf-devtools--host-label (info)
  "Format concise selector label for inspected Host INFO."
  (let ((comp (plist-get info :owner-component-name))
        (tag (plist-get info :tag))
        (dom-id (plist-get info :dom-id))
        (classes (plist-get info :classes))
        (ref (plist-get info :ref)))
    (concat (if comp (format "%s › " comp) "")
            (symbol-name (or tag 'host))
            (if classes (concat "." (mapconcat #'identity classes ".")) "")
            (if dom-id (format "#%s" dom-id) "")
            (if (and ref (not dom-id)
                     (not (and (consp ref) (eq (car ref) 'etaf-host))))
                (format " :ref %s" ref) ""))))

(defun etaf-devtools--overlay-highlight-host (runtime host-id &optional show-badge)
  "Highlight HOST-ID in RUNTIME's buffer using clean, zero-distortion overlays.
Applies a soft translucent-style background tint with 1px top/bottom boundary
lines only on the first and last rows (never per-line `:box' stripes).  When
the inspected Host covers at least 80% of a tall viewport (such as a root
shell), automatically de-noises by drawing only the top/bottom boundary lines
so inner content stays clear.  Returns non-nil when any span was highlighted."
  (etaf-devtools--overlay-clear-selection)
  (when (and runtime (etaf-runtime-mounted-p runtime) (integerp host-id))
    (let* ((buf (etaf-runtime-buffer runtime))
           (info (condition-case nil
                     (etaf-runtime-inspect-host runtime host-id)
                   (error nil)))
           (spans (plist-get info :row-spans)))
      (when (and (buffer-live-p buf) spans)
        (let* ((win (get-buffer-window buf t))
               (fr (if (window-live-p win) (window-frame win) (selected-frame)))
               (pal (etaf-devtools--palette fr))
               (fill (plist-get pal :highlight-fill))
               (accent (plist-get pal :accent))
               (valid-spans
                (with-current-buffer buf
                  (cl-remove-if-not
                   (lambda (sp)
                     (let ((beg (cadr sp)) (end (cddr sp)))
                       (and (integerp beg) (integerp end)
                            (>= beg (point-min)) (<= end (point-max))
                            (< beg end))))
                   spans)))
               (total (length valid-spans))
               (vp-rows (max 1 (or (and (window-live-p win) (window-body-height win))
                                   (with-current-buffer buf
                                     (count-lines (point-min) (point-max))))))
               ;; Auto-de-noise when highlighting a full-viewport root shell
               (full-screen-p (and (>= total 12)
                                   (>= (* total 100) (* vp-rows 80))))
               (ovs nil))
          (when (> total 0)
            (with-current-buffer buf
              (let ((idx 0)
                    (last (1- total)))
                (dolist (span valid-spans)
                  (let* ((beg (cadr span))
                         (end (cddr span))
                         (first-p (= idx 0))
                         (last-p (= idx last))
                         (face nil))
                    (unless full-screen-p
                      (setq face (plist-put face :background fill)))
                    (when first-p
                      (setq face (plist-put face :overline accent)))
                    (when last-p
                      (setq face (plist-put face :underline
                                            (list :color accent :position t))))
                    (when face
                      (let ((ov (make-overlay beg end buf t nil)))
                        (overlay-put ov 'etaf-devtools-overlay 'selection)
                        (overlay-put ov 'priority 900)
                        (overlay-put ov 'face face)
                        (push ov ovs))))
                  (setq idx (1+ idx))))))
          (setq etaf-devtools--selection-overlays (nreverse ovs))
          (when (and show-badge ovs)
            (let* ((geo (plist-get info :geometry))
                   (size-str (if geo
                                 (format "%dpx × %dL"
                                         (or (plist-get geo :width) 0)
                                         (or (plist-get geo :height) 0))
                               "")))
              (etaf-devtools--show-badge
               buf (etaf-devtools--truncate (etaf-devtools--host-label info) 44)
               size-str pal)))
          (and ovs t))))))

(defun etaf-devtools--flash-sweep ()
  "Expire finished Highlight Updates overlays and stop timer when empty."
  (let ((now (float-time))
        (kept nil))
    (dolist (entry etaf-devtools--flash-entries)
      (if (<= (car entry) now)
          (when (overlayp (cdr entry))
            (delete-overlay (cdr entry)))
        (push entry kept)))
    (setq etaf-devtools--flash-entries (nreverse kept))
    (unless etaf-devtools--flash-entries
      (when (timerp etaf-devtools--flash-timer)
        (cancel-timer etaf-devtools--flash-timer))
      (setq etaf-devtools--flash-timer nil))))

(defun etaf-devtools--overlay-clear-flashes (&optional buffer)
  "Remove Highlight Updates overlays for BUFFER, or all when BUFFER is nil."
  (let ((kept nil))
    (dolist (entry etaf-devtools--flash-entries)
      (let ((ov (cdr entry)))
        (if (or (null buffer)
                (not (overlayp ov))
                (eq (overlay-buffer ov) buffer))
            (when (overlayp ov) (delete-overlay ov))
          (push entry kept))))
    (setq etaf-devtools--flash-entries (nreverse kept))
    (unless etaf-devtools--flash-entries
      (when (timerp etaf-devtools--flash-timer)
        (cancel-timer etaf-devtools--flash-timer))
      (setq etaf-devtools--flash-timer nil))))

(defun etaf-devtools--overlay-flash-report (runtime report)
  "Flash changed lines from Ebox flush REPORT in RUNTIME's buffer."
  (when (and runtime (etaf-runtime-mounted-p runtime) report)
    (let* ((buf (etaf-runtime-buffer runtime))
           (now (float-time))
           (prev (and (buffer-live-p buf) (gethash buf etaf-devtools--flash-last-at))))
      (when (and (buffer-live-p buf)
                 (or (null prev) (>= (- now prev) 0.08)))
        (puthash buf now etaf-devtools--flash-last-at)
        (let* ((strategy (plist-get report :strategy))
               (full-p (eq strategy 'full))
               (ranges (plist-get report :ranges))
               (win (get-buffer-window buf t))
               (fr (if (window-live-p win) (window-frame win) (selected-frame)))
               (pal (etaf-devtools--palette fr))
               (bg (plist-get pal (if full-p :flash-full :flash-inc)))
               (dur (if full-p
                        etaf-devtools-full-highlight-duration
                      etaf-devtools-highlight-duration))
               (expire (+ now dur)))
          (with-current-buffer buf
            (save-excursion
              (let ((line-ranges
                     (if ranges
                         ranges
                       (list (list 0 0 (max 1 (count-lines (point-min) (point-max))))))))
                (dolist (rng line-ranges)
                  (let ((start-line (or (nth 0 rng) 0))
                        (count (max 1 (or (nth 2 rng) 1))))
                    (goto-char (point-min))
                    (when (zerop (forward-line start-line))
                      (let ((beg (line-beginning-position)))
                        (forward-line (1- count))
                        (let ((end (line-end-position)))
                          (when (< beg end)
                            (let ((ov (make-overlay beg end buf t nil)))
                              (overlay-put ov 'etaf-devtools-overlay 'flash)
                              (overlay-put ov 'priority 850)
                              (overlay-put ov 'face (list :background bg))
                              (push (cons expire ov) etaf-devtools--flash-entries)))))))))))
          (when (and etaf-devtools--flash-entries
                     (not (timerp etaf-devtools--flash-timer)))
            (setq etaf-devtools--flash-timer
                  (run-with-timer 0.1 0.1 #'etaf-devtools--flash-sweep))))))))

(defun etaf-devtools--overlay-clear-all ()
  "Clear every selection overlay, badge and flash overlay."
  (etaf-devtools--overlay-clear-selection)
  (etaf-devtools--overlay-clear-flashes))

(provide 'etaf-devtools-overlay)
;;; etaf-devtools-overlay.el ends here
