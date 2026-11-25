;;; etaf-md-live.el --- Keep a preview in step with its source  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A preview is a rendering of a markdown file, so it is read-only: the file is
;; edited in its own buffer, with every Emacs command the reader already has,
;; and this module keeps the page in step with it.  A change repaints the page
;; from the edited text on the next frame, block by block: the blocks that did
;; not change keep their published instance, so typing in the source costs the
;; block under the caret rather than the whole document.

;;; Code:

(require 'etaf)
(require 'etaf-md-app)
(require 'etaf-md-model)
(require 'etaf-md-views)

;;;; Repainting the page

(defun etaf-md--live-repaint (session &optional text dirty-span live-p)
  "Redraw SESSION's page from its markdown, now.
When TEXT is supplied, publishes it directly without copying the source buffer
a second time.  DIRTY-SPAN and LIVE-P forward incremental edit metadata to the
parser."
  (let ((contents (or text (etaf-md--session-text session))))
    (etaf-md--publish session contents dirty-span live-p)
    ;; The text this page now shows, so a scheduled follow that finds the same
    ;; text knows there is nothing left to draw.
    (plist-put session :live-text contents))
  (when-let* ((buffer (plist-get session :buffer))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer))))
    (etaf-runtime-flush runtime)))

(defun etaf-md--live-refresh (session text &optional dirty-span live-p)
  "Redraw SESSION from TEXT, the current markdown."
  (unless (plist-get session :source-buffer)
    (plist-put session :text text))
  (etaf-md--live-repaint session text dirty-span live-p))

(provide 'etaf-md-live)

;;; etaf-md-live.el ends here
