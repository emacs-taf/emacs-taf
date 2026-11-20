;;; etaf-ui-icon-gui.el --- Physical icon row and font acceptance -*- lexical-binding: t; -*-

;;; Commentary:
;; The command runner loads this file through an existing GUI Emacs server.
;; Each timer turn measures one public component in a private hidden frame.
;; Registry additions participate automatically, including partial font maps.

;;; Code:

(require 'cl-lib)
(require 'etaf-ui)

(defun etaf-ui-icon-gui--finish (state error)
  "Write STATE's report and completion status, including optional ERROR."
  (let ((buffer (plist-get state :buffer))
        (frame (plist-get state :frame))
        (rows (nreverse (plist-get state :rows)))
        (failed error))
    (unwind-protect
        (with-temp-file (plist-get state :report)
          (insert (format "Icon check: Emacs %s, standard line %d px\n"
                          emacs-version (frame-char-height frame)))
          (insert (format "%-18s %-10s %-32s %6s %8s %s\n"
                          "icon/variant" "set" "resolved family" "row px" "expected" "result"))
          (dolist (row rows)
            (pcase-let ((`(,name ,set ,family ,height ,expected ,ok) row))
              (unless ok (setq failed t))
              (insert (format "%-18s %-10s %-32s %6s %8d %s\n"
                              name set family height expected (if ok "PASS" "FAIL")))))
          (when error (insert (format "ERROR: %s\n" error)))
          (insert "\nSet summary (all variants, including both oversized rows):\n")
          (insert (format "%-10s %5s %7s %-32s %10s %8s\n"
                          "set" "icons" "rows" "family" "row px" "expected"))
          (dolist (set (etaf-ui-icon-sets))
            (let* ((selected (cl-remove-if-not (lambda (row) (eq (nth 1 row) set)) rows))
                   (heights (delete-dups (mapcar (lambda (row) (nth 3 row)) selected))))
              (insert (format "%-10s %5d %7d %-32s %10s %8d\n"
                              set (length (etaf-ui-icon-names set)) (length selected)
                              (or (plist-get (etaf-ui-icon-set-spec set) :family) "SVG/currentColor")
                              (mapconcat (lambda (h) (format "%s" h)) heights ",")
                              (frame-char-height frame)))))
          (insert (format "\n%s: %d physical rows checked\n" (if failed "FAIL" "PASS") (length rows))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (frame-live-p frame) (delete-frame frame t))
      (with-temp-file (concat (plist-get state :report) ".status")
        (insert (if failed "1" "0"))))))

(defun etaf-ui-icon-gui--step (state)
  "Measure the next public icon in STATE, yielding between components."
  (condition-case problem
      (if (null (plist-get state :pending))
          (etaf-ui-icon-gui--finish state nil)
        (pcase-let* ((`(,set ,name ,size ,lines ,variant)
                      (pop (plist-get state :pending)))
                     (frame (plist-get state :frame))
                     (buffer (plist-get state :buffer))
                     (spec (etaf-ui-icon-set-spec set))
                     (expected (frame-char-height frame))
                     (glyph (cdr (assq name (plist-get spec :glyphs))))
                     (pressed 0))
          (with-selected-frame frame
            (with-current-buffer buffer
              (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
              (etaf-mount buffer (etaf-ui-icon name :set set :size size :lines lines
                                             :min-width 4 :ref 'icon
                                             :on-press (lambda () (cl-incf pressed))))
              (set-window-buffer (frame-selected-window frame) buffer)
              (setq-local line-spacing nil)
              (goto-char (point-min))
              (redisplay t)
              (let* ((runtime (etaf-runtime-for-buffer buffer))
                     (family (if (eq (plist-get spec :kind) 'font)
                                 (if (= lines 2) "SVG/font"
                                   (save-excursion
                                     (when (search-forward glyph nil t)
                                       (let ((font (font-at (1- (point)) (selected-window))))
                                         (and font (format "%s" (font-get font :family)))))))
                               "SVG/currentColor"))
                     (family-ok (or (not glyph) (= lines 2)
                                    (equal family (plist-get spec :family))))
                     (row 0))
                (etaf-dispatch-event runtime 'icon 'press)
                (unless (= pressed 1) (error "Icon %s/%s lost its press target" set name))
                (while (< (point) (point-max))
                  (let ((height (line-pixel-height)))
                    (push (list (format "%s/%s:%d" name variant (1+ row))
                                set (or family "MISSING") height expected
                                (and family-ok (= height expected)))
                          (plist-get state :rows)))
                  (cl-incf row)
                  (forward-line 1))
                (unless (= row lines)
                  (error "Icon %s/%s occupies %d rows, expected %d" set name row lines)))))
          (run-at-time 0.001 nil #'etaf-ui-icon-gui--step state)))
    (error (etaf-ui-icon-gui--finish state (error-message-string problem)))))

(defun etaf-ui-icon-gui-start (report)
  "Check every registered set in a hidden GUI frame and write REPORT.
The runner reads REPORT.status: 0 means pass, 1 means failure.  No existing
frame or application buffer is changed.  Return immediately after scheduling."
  (let ((parent (cl-find-if #'display-graphic-p (frame-list))))
    (unless parent (user-error "icon-check requires a graphical Emacs frame; none is available"))
    (with-selected-frame parent
      (let* ((frame (make-frame '((visibility . nil) (width . 60) (height . 8)
                                 (minibuffer . nil) (line-spacing . nil))))
             (buffer (generate-new-buffer " *etaf-ui-icon-check*"))
             (pending
              (cl-loop for set in (etaf-ui-icon-sets) append
                       (cl-loop for name in (etaf-ui-icon-names set) append
                                (list (list set name 1.0 1 'normal)
                                      (list set name 0.5 1 'small)
                                      (list set name 8.0 1 'clamped)
                                      (list set name 2.0 2 'double))))))
        (unless pending (error "Icon registry is empty"))
        (run-at-time 0 nil #'etaf-ui-icon-gui--step
                     (list :frame frame :buffer buffer :report report
                           :pending pending :rows nil)))))
  'scheduled)

;;; etaf-ui-icon-gui.el ends here
