;;; etaf-md-live.el --- Keep a preview in step with its source  -*- lexical-binding: t; -*-

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

(defun etaf-md--live-repaint (session)
  "Redraw SESSION's page from its markdown, now."
  (let ((text (etaf-md--session-text session)))
    (etaf-md--publish session text)
    ;; The text this page now shows, so a scheduled follow that finds the same
    ;; text knows there is nothing left to draw.
    (plist-put session :live-text text))
  (when-let* ((buffer (plist-get session :buffer))
              (runtime (and (buffer-live-p buffer)
                            (etaf-runtime-for-buffer buffer))))
    (etaf-runtime-flush runtime)))

(defun etaf-md--live-refresh (session text)
  "Redraw SESSION from TEXT, the current markdown."
  (unless (plist-get session :source-buffer)
    (plist-put session :text text))
  (etaf-md--live-repaint session))

(provide 'etaf-md-live)

;;; etaf-md-live.el ends here
