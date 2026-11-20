;;; weread-gui-probe.el --- Drive and inspect a live reader -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader's layout invariants can only be checked in a real frame: the
;; model budgets its page in lines, and a row painted taller than the line
;; height silently pushes the canvas past the window.  This file is the
;; maintained probe a GUI check loads, so probes stop being throwaway files
;; that bypass the byte-compilation gate.
;;
;; Load it in a graphical Emacs, then:
;;
;;   (etaf-weread-gui-open "150x40")   ; mount the reader at a frame size
;;   (etaf-weread-gui-status)          ; one-line state for logging
;;   (etaf-weread-gui-keys "jj RET")   ; real keys through the command loop
;;   (etaf-weread-gui-check)           ; layout invariants; nil when healthy
;;
;; `etaf-weread-gui-wait' polls until the shelf arrives, which keeps a probe
;; from asserting on a loading reader.  Nothing here is part of the package's
;; public API.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'etaf-weread)

(defvar etaf-weread-gui--model nil
  "Reader session the probe drives, or nil before the first open.")

(defun etaf-weread-gui-open (&optional size)
  "Mount the reader in the selected frame at SIZE, a \"WIDTHxHEIGHT\" string.
SIZE defaults to `WEREAD_GUI_SIZE' or \"150x40\".  Return the new session."
  (let* ((size (or size (getenv "WEREAD_GUI_SIZE") "150x40"))
         (parts (split-string size "x"))
         (frame (selected-frame)))
    (set-frame-parameter frame 'fullscreen nil)
    (set-frame-size frame (string-to-number (car parts)) (string-to-number (cadr parts)))
    (delete-other-windows)
    (setq etaf-weread-gui--model (etaf-weread-create))
    (etaf-weread-refresh etaf-weread-gui--model)
    (etaf-weread-open etaf-weread-gui--model)
    (delete-other-windows)
    etaf-weread-gui--model))

(defun etaf-weread-gui-wait (&optional seconds)
  "Wait up to SECONDS (default 30) for the reader's first rows."
  (let ((deadline (+ (float-time) (or seconds 30))))
    (while (and (< (float-time) deadline)
                (not (> (or (plist-get (etaf-weread-gui--state) :rows-total) 0) 0)))
      (sit-for 0.25))
    (> (or (plist-get (etaf-weread-gui--state) :rows-total) 0) 0)))

(defun etaf-weread-gui--state ()
  "Return the probe session's state, or nil when it has no session."
  (and etaf-weread-gui--model (etaf-weread-state etaf-weread-gui--model)))

(defun etaf-weread-gui-status ()
  "Return a one-line summary of the reader's state for logging."
  (let* ((state (etaf-weread-gui--state))
         (notes (plist-get state :notes))
         (detail (plist-get state :detail)))
    (format "frame=%dx%d layout=%s section=%s pane=%s sel=%s rows=%s/%s notes=%s detail=%s"
            (frame-width) (frame-height)
            (plist-get state :layout) (plist-get state :section) (plist-get state :pane)
            (plist-get state :selection) (plist-get state :rows-total)
            (plist-get state :list-total) (plist-get notes :count)
            (plist-get detail :title))))

(defun etaf-weread-gui-keys (keys)
  "Send KEYS through the real command loop and return the new status.
KEYS is a `kbd' string, so \"jj RET\" moves the selection twice and opens it."
  (with-current-buffer (get-buffer etaf-weread-buffer-name)
    (execute-kbd-macro (kbd keys)))
  (etaf-weread-gui-status))

(defun etaf-weread-gui-canvas-pixels ()
  "Return (TOTAL . TALL) for the reader canvas in the selected frame.
TOTAL is the pixel height of every canvas line.  TALL counts the lines taller
than the page budget's row height, so a glyph that outgrows its budget — the
way a font that falls back to a taller face does — is visible here.  A line
shorter than the budget is fine: a blank or Latin-only row may not reach the
height a CJK row does."
  (with-current-buffer (get-buffer etaf-weread-buffer-name)
    (let* ((limit (frame-char-height))
           (total 0) (tall 0))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (let ((height (line-pixel-height)))
            (setq total (+ total height))
            (when (> height limit) (cl-incf tall)))
          (forward-line 1)))
      (cons total tall))))

(defun etaf-weread-gui-check ()
  "Return the layout problems of the displayed reader, or nil when healthy.
The canvas must fit the window that shows it, no row may be taller than the
line height the page budget counts, and both binding hints must arrive whole."
  (let* ((window (get-buffer-window etaf-weread-buffer-name t))
         (canvas (etaf-weread-gui-canvas-pixels))
         (widest-line (with-current-buffer (get-buffer etaf-weread-buffer-name)
                        (let ((width 0))
                          (save-excursion
                            (goto-char (point-min))
                            (while (not (eobp))
                              (setq width
                                    (max width
                                         (car (window-text-pixel-size
                                               window (line-beginning-position)
                                               (line-end-position)))))
                              (forward-line 1)))
                          width)))
         (text (with-current-buffer (get-buffer etaf-weread-buffer-name)
                 (buffer-substring-no-properties (point-min) (point-max))))
         (state (etaf-weread-gui--state))
         (hints (cond
                 ((eq (plist-get state :layout) 'wide)
                  (list "g 刷新 · v 笔记 · o 浏览器 · E 导出 · T 深浅色 · ? 帮助"))
                 ((eq (plist-get state :layout) 'narrow) (list "? 帮助"))
                 (t (list "↑/↓ 选择 · RET 打开 · v 切换面板"))))
         (problems (delq nil
                         (list (unless (and window
                                            (<= (car canvas) (window-pixel-height window)))
                                 (format "canvas %spx does not fit window %spx"
                                         (car canvas) (and window (window-pixel-height window))))
                               (unless (and window
                                            (<= widest-line (window-body-width window t)))
                                 (format "widest canvas line %spx exceeds window body width %spx"
                                         widest-line (and window (window-body-width window t))))
                               (unless (zerop (cdr canvas))
                                 (format "%s row(s) are taller than the page budget"
                                         (cdr canvas)))
                               (seq-find (lambda (hint)
                                           (not (string-match-p (regexp-quote hint) text)))
                                         hints)
                               (unless (cl-every (lambda (hint)
                                                   (string-match-p (regexp-quote hint) text))
                                                 hints)
                                 (format "hint not painted whole: %S" hints))))))
    problems))

(defun etaf-weread-gui--flush ()
  "Apply the renderer's retained updates to the probe buffer.
`line-pixel-height' reads the painted text properties, so no window redisplay
is needed and a probe never waits on the window system."
  (etaf-runtime-flush (etaf-runtime-for-buffer (get-buffer etaf-weread-buffer-name))))

(provide 'weread-gui-probe)
;;; weread-gui-probe.el ends here
