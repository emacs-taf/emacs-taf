;;; etaf-web-app.el --- Open compiled web pages via etaf-md -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Entry command wiring `etaf-web-cache' and `etaf-md': prepares the cached
;; `index.md' for a URL or local HTML file and mounts it using `etaf-md's
;; existing reading view with `:on-link' routing HTTP(S) clicks back through
;; `etaf-web-open'.

;;; Code:

(require 'etaf-md)
(require 'etaf-web-cache)

(defun etaf-web--select-other-window ()
  "Select another window for `other-window' display, splitting if needed."
  (let ((target (if (one-window-p t)
                    (or (split-window-sensibly)
                        (ignore-errors (split-window-right))
                        (selected-window))
                  (next-window))))
    (when (window-live-p target)
      (select-window target))))

(defun etaf-web-open (source &optional other-window)
  "Open web page or local HTML file SOURCE in an `etaf-md' reading buffer.
SOURCE is either a local HTML file path (or `file://' URL) or an `http://' /
`https://' URL.  Reads or fetches SOURCE, compiles it to `index.md' under
`etaf-web-cache-directory', caches bounded images when
`etaf-web-download-images' is non-nil, and opens the preview via `etaf-md'.
With OTHER-WINDOW non-nil, displays the preview in another window.  Returns the
preview buffer; signals `etaf-web-error' on invalid input or fetch failure."
  (interactive
   (list (read-string "Web URL or HTML file: ") current-prefix-arg))
  (let* ((prepared (etaf-web--prepare-page source))
         (index-file (plist-get prepared :index-file))
         (title (plist-get prepared :title))
         (session (etaf-md-create
                   :file index-file
                   :title title
                   :on-link (lambda (url)
                              (when (etaf-web--http-url-p url)
                                (etaf-web-open url)
                                t)))))
    (when other-window
      (etaf-web--select-other-window))
    (etaf-md-open session)))

(provide 'etaf-web-app)
;;; etaf-web-app.el ends here
