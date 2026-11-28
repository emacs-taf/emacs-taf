;;; etaf-md-gui-probe.el --- Drive and inspect a live preview -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The preview's typography can only be judged in a real graphical frame:
;; heading scales, the reading measure, media grids and link hit areas depend
;; on the frame's fonts and pixel metrics.  This file is the maintained probe
;; a GUI check loads, so probes stop being throwaway files that bypass the
;; byte-compilation gate.
;;
;; Load it in a graphical Emacs with this repository and the provider roots on
;; `load-path', then:
;;
;;   (etaf-md-gui-open "README.md" "150x44")  ; open at a frame size
;;   (etaf-md-gui-status)                     ; one-line state for logs
;;   (etaf-md-gui-keys "nt")                  ; real keys through the loop
;;   (etaf-md-gui-follow "appended by a tool")  ; write the source
;;   (etaf-md-gui-follow-report "appended by a tool" LINE) ; then wait
;;   (etaf-md-gui-check)                      ; invariants; nil when healthy
;;   (etaf-md-gui-close)                      ; release the preview buffer
;;
;; Nothing here is part of the package's public API.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf-md)

(defvar etaf-md-gui--session nil
  "Preview session the probe drives, or nil before the first open.")

(defun etaf-md-gui-open (&optional file size)
  "Open FILE as a preview in the selected frame sized SIZE.
SIZE is a \"WIDTHxHEIGHT\" string and defaults to `MD_PREVIEW_GUI_SIZE' or
\"150x44\".  FILE defaults to the repository README.  Return the new session."
  (let* ((size (or size (getenv "MD_PREVIEW_GUI_SIZE") "150x44"))
         (parts (split-string size "x"))
         (frame (selected-frame))
         (file (or file (getenv "MD_PREVIEW_GUI_FILE")
                   (expand-file-name "README.md"
                                     (file-name-directory
                                      (directory-file-name
                                       (file-name-directory (or load-file-name
                                                                buffer-file-name))))))))
    (set-frame-parameter frame 'fullscreen nil)
    (set-frame-size frame (string-to-number (car parts))
                    (string-to-number (cadr parts)))
    (delete-other-windows)
    (setq etaf-md-gui--session (etaf-md-create :file file))
    (etaf-md-open etaf-md-gui--session)
    (delete-other-windows)
    etaf-md-gui--session))

(defun etaf-md-gui-close ()
  "Unmount and kill the probe's preview buffer."
  (when-let* ((session etaf-md-gui--session)
              (buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (etaf-md-close))))
  (setq etaf-md-gui--session nil))

(defun etaf-md-gui-status ()
  "Return a one-line summary of the preview's state for logging."
  (let ((state (and etaf-md-gui--session
                    (etaf-md-state etaf-md-gui--session))))
    (format "frame=%dx%d theme=%s width=%s blocks=%s outline=%s footnotes=%s"
            (frame-width) (frame-height)
            (plist-get state :theme) (plist-get state :width)
            (plist-get state :blocks) (length (plist-get state :outline))
            (length (plist-get state :footnotes)))))

(defun etaf-md-gui-keys (keys)
  "Send KEYS through the real command loop and return the new status.
KEYS is a `kbd' string, so \"nt\" moves to the next heading and cycles theme."
  (let ((buffer (and etaf-md-gui--session
                     (plist-get etaf-md-gui--session :buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (execute-kbd-macro (kbd keys)))))
  (etaf-md-gui-status))

(defun etaf-md-gui-follow (text)
  "Append TEXT to the probe's source on disk and return the reader's position.
The write happens outside any buffer, the way another program saves a file, so
a caller exercises the follow path instead of a forced reload.  This returns
before the repaint: the repaint runs from a timer once Emacs is idle, so a
caller waiting inside another timer or a client request would starve it.
Return a plist of `:file' and `:line', the reader's line at the write."
  (let ((file (and etaf-md-gui--session
                   (plist-get etaf-md-gui--session :file)))
        (buffer (and etaf-md-gui--session
                     (plist-get etaf-md-gui--session :buffer))))
    (unless file
      (error "The probe has no file-backed preview to follow"))
    (let ((line (and (buffer-live-p buffer)
                     (with-current-buffer buffer (line-number-at-pos)))))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-max))
        (insert "\n" text "\n")
        (write-region (point-min) (point-max) file nil 'silent))
      (list :file file :line line))))

(defun etaf-md-gui-follow-report (text &optional before)
  "Wait for the follow repaint of TEXT and report what the preview did.
BEFORE is the reader's line captured by `etaf-md-gui-follow', which
lets the caller see that the repaint kept the reader in its section.  Call
this at top level: a timer cannot run the repaint while another timer waits.
Return `:line', `:kept' (the reader stayed within three lines of BEFORE) and
`:followed' (the new text reached the buffer)."
  (let ((buffer (and etaf-md-gui--session
                     (plist-get etaf-md-gui--session :buffer))))
    (unless (buffer-live-p buffer)
      (error "The probe has no preview buffer to inspect"))
    (let ((waited 0)
          (found nil))
      (while (and (not found) (< waited 40))
        (setq found (with-current-buffer buffer
                      (string-match-p (regexp-quote text) (buffer-string))))
        (unless found
          (sit-for 0.1)
          (setq waited (1+ waited))))
      (let ((line (with-current-buffer buffer (line-number-at-pos))))
        (list :line line
              :kept (and before (<= (abs (- line before)) 3))
              :followed (and found t))))))

(defun etaf-md-gui-check ()
  "Return preview layout problems, or nil when the frame looks healthy.
Checks the invariants a text frame can violate silently: painted lines that
are wider than the window, a picture row cut for another measure, a missing
heading outline, and links that lost their activation keymap."
  (let* ((session etaf-md-gui--session)
         (buffer (and session (plist-get session :buffer)))
         (problems nil))
    (unless (buffer-live-p buffer)
      (push "no live preview buffer" problems))
    (when (buffer-live-p buffer)
      (setq problems (nconc (etaf-md-gui--picture-problems buffer) problems))
      (with-current-buffer buffer
        (let* ((window (get-buffer-window buffer t))
               (columns (and (window-live-p window) (window-body-width window)))
               (position (point-min))
               (links 0))
          (unless (window-live-p window)
            (push "the preview buffer is not shown in a live window" problems))
          (when columns
            (save-excursion
              (goto-char (point-min))
              (while (not (eobp))
                (let* ((line (buffer-substring (line-beginning-position)
                                               (line-end-position)))
                       (width (string-width (substring-no-properties line))))
                  (when (> width columns)
                    (push (format "line %d is %d columns in a %d-column window"
                                  (line-number-at-pos) width columns)
                          problems)))
                (forward-line 1))))
          (while (< position (point-max))
            (when (get-text-property position 'keymap)
              (cl-incf links))
            (setq position (next-property-change position nil (point-max))))
          (unless (> links 0)
            (push "the document rendered without any interactive link" problems)))
        (unless (plist-get (etaf-md-state session) :outline)
          (push "the document has no outline" problems))))
    (nreverse problems)))

(defun etaf-md-gui--slice (display)
  "Return DISPLAY's slice spec, or nil when it carries no image slice.
A picture row's display is the slice spec followed by its image descriptor:
`((slice 0 Y W H) IMAGE)'.  Emacs also accepts the bare `(slice ...)' spec, so
both shapes name the same thing here."
  (cond
   ((not (consp display)) nil)
   ((eq (car display) 'slice) display)
   ((and (consp (car display)) (eq (car (car display)) 'slice)) (car display))))

(defun etaf-md-gui--line-slice (beg end)
  "Return the slice spec BEG..END carries, or nil."
  (let ((position beg) (value nil))
    (while (and (< position end) (null value))
      (setq value (etaf-md-gui--slice (get-char-property position 'display)))
      (setq position (1+ position)))
    value))

(defun etaf-md-gui--picture-problems (buffer)
  "Return the picture rows of BUFFER that do not fit the lines they sit on.
A picture is a run of rows cut for one measure: every row is as tall as the
line it is painted on, and the run begins once.  A row that leaves its line's
height is a picture cut for another measure, and a run that begins twice is a
second drawing over the first - the two ways a picture arrives doubled, with
gaps between its rows, or out of line with the text around it."
  (with-current-buffer buffer
    (let ((window (get-buffer-window buffer t))
          (position (point-min))
          (problems nil)
          (rows 0)
          (last-line -2))
      (when (window-live-p window)
        (while (< position (point-max))
          (let ((slice (etaf-md-gui--slice (get-char-property position 'display))))
            (when slice
              (let* ((line (line-number-at-pos position))
                     (height (nth 4 slice))
                     (painted (with-selected-window window
                                (save-excursion
                                  (goto-char position)
                                  (line-pixel-height)))))
                (unless (= height painted)
                  (push (format "line %d: a picture row is %d tall in a %d line"
                                line height painted)
                        problems))
                (when (and (zerop (nth 2 slice))
                           (> rows 0)
                           (= line (1+ last-line)))
                  (push (format "line %d: a picture begins again inside one run" line)
                        problems))
                (setq rows (if (= line (1+ last-line)) (1+ rows) 1)
                      last-line line))))
          (setq position (or (next-single-property-change position 'display nil (point-max))
                             (point-max)))))
      (nreverse problems))))

(defun etaf-md-gui-table-boundaries (header)
  "Check every displayed table row below HEADER against its column boundaries.
Measure actual screen positions, not string widths: post-publication font
changes can invalidate layout measurements.  The entire table must be visible.
Return its row boundary lists or signal an error for missing or shifted edges."
  (let* ((buffer (plist-get etaf-md-gui--session :buffer))
         (window (get-buffer-window buffer t))
         rows expected border-color)
    (unless (window-live-p window)
      (error "Preview has no displayed window"))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (search-forward header)
        (beginning-of-line)
        (let ((continue t))
          (while (and continue (not (eobp)))
            (let ((position (point)) (end (line-end-position)) edges)
              (while (< position end)
                (when (equal (get-text-property position 'display)
                             '(space :width (1)))
                  (let* ((face (get-text-property position 'face))
                         (faces (if (keywordp (car-safe face)) (list face) face))
                         (color (seq-some
                                 (lambda (entry)
                                   (and (listp entry) (plist-get entry :background)))
                                 faces)))
                    ;; A one-pixel filler is not a border.  Use the first
                    ;; outer edge's paint to distinguish them at narrow widths.
                    (unless border-color (setq border-color color))
                    (when (and color (equal color border-color))
                      (let ((screen (posn-at-point position window)))
                        (unless screen
                          (error "Table row %d is not visible" (line-number-at-pos)))
                        (push (car (posn-x-y screen)) edges)))))
                (setq position (1+ position)))
              (setq edges (nreverse edges))
              (if (null edges)
                  (setq continue nil)
                (unless expected (setq expected edges))
                (unless (equal expected edges)
                  (error "Table row %d boundaries %S differ from %S"
                         (line-number-at-pos) edges expected))
                (push edges rows)))
            (forward-line 1)))))
    (unless (> (length rows) 1)
      (error "No complete table found for %s" header))
    (nreverse rows)))

(provide 'etaf-md-gui-probe)
;;; etaf-md-gui-probe.el ends here
