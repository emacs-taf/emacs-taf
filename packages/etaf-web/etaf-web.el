;;; etaf-web.el --- Compile web pages to etaf-md reading views -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf-md "0.2.0"))
;; Keywords: hypermedia, web, docs
;; URL: https://github.com/emacs-taf/etaf-web

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-web) after adding this repository and
;; the ETAF, ETAF UI, ETAF MD, Ebox and ECSS roots to `load-path'.  ETAF Web
;; compiles HTML documents into the text-level intermediate language accepted
;; by `etaf-md' (YAML front matter, Markdown and `:::' containers), writes the
;; compiled page and bounded image assets into a local cache directory, and
;; presents each page inside its own ETAF browser buffer with navigation
;; history, address bar, asynchronous non-blocking loading and error recovery.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions, and
;; docs/manual.md contains workflows.
;;
;; Function: etaf-web-to-markdown (html &key base-url)
;;;###autoload (autoload 'etaf-web-to-markdown "etaf-web" nil nil)
;; Compile HTML string into `etaf-md' intermediate language text.
;; Pure function with no network or disk I/O.  Strips unsafe tags, event
;; handler attributes, hidden nodes and dangerous link schemes, extracts the
;; primary content and YAML front matter, resolves relative links and images
;; against BASE-URL when supplied, and emits normalized Markdown plus `:::'
;; containers.  Signals `etaf-web-error' if HTML is not a string or Emacs lacks
;; libxml.
;;
;; Function: etaf-web-open (source &optional other-window)
;;;###autoload (autoload 'etaf-web-open "etaf-web" nil t)
;; Open a web page or local HTML file SOURCE in its own ETAF Web browser buffer
;; (`*Web: <host>*').  SOURCE is either a local HTML file path (or `file://'
;; URL) or an `http://' / `https://' URL.  Returns the browser buffer
;; immediately while HTTP fetching, optional headless rendering, compilation
;; and background image caching run asynchronously without blocking Emacs.
;; Reuses an existing cached `index.md' on repeated opens while backfilling any
;; missing images in the background.  With OTHER-WINDOW non-nil, displays the
;; buffer in another window.  Signals `etaf-web-error' synchronously on invalid
;; SOURCE or unreadable local files; network/HTTP failures display a readable
;; error card with retry and browser actions inside the buffer.
;;
;; Function: etaf-web-back ()
;;;###autoload (autoload 'etaf-web-back "etaf-web" nil t)
;; Navigate backward in the current ETAF Web browser buffer's history stack,
;; restoring the previous scroll position.
;;
;; Function: etaf-web-forward ()
;;;###autoload (autoload 'etaf-web-forward "etaf-web" nil t)
;; Navigate forward in the current ETAF Web browser buffer's history stack,
;; restoring its scroll position.
;;
;; Function: etaf-web-reload ()
;;;###autoload (autoload 'etaf-web-reload "etaf-web" nil t)
;; Re-fetch and recompile the current ETAF Web page bypassing on-disk cache.
;;
;; Function: etaf-web-stop ()
;;;###autoload (autoload 'etaf-web-stop "etaf-web" nil t)
;; Cancel any in-flight HTTP fetch, headless render or background image job in
;; the current ETAF Web buffer without leaving orphan subprocesses.
;;
;; Function: etaf-web-focus-address ()
;;;###autoload (autoload 'etaf-web-focus-address "etaf-web" nil t)
;; Focus and edit the inline address bar (with history completion) in the
;; current ETAF Web buffer.
;;
;; Function: etaf-web-open-external ()
;;;###autoload (autoload 'etaf-web-open-external "etaf-web" nil t)
;; Open the current ETAF Web page's URL in the external system browser.
;;
;; Function: etaf-web-close ()
;;;###autoload (autoload 'etaf-web-close "etaf-web" nil t)
;; Close the current ETAF Web browser buffer, cancelling any active loads.
;;
;; Function: etaf-web-state (&optional buffer)
;;;###autoload (autoload 'etaf-web-state "etaf-web" nil nil)
;; Return a detached state plist snapshot for ETAF Web BUFFER (default current).
;; Keys include `:url', `:title', `:phase' (`loading', `ready' or `error'),
;; `:stage', `:progress', `:cached', `:error', `:can-back', `:can-forward',
;; `:history-length', `:address-editing', `:narrow' and `:width'.
;;
;; Variable: etaf-web-cache-directory (default "~/.cache/etaf-web/")
;; Root directory where cached pages, `index.md', `source.html', `meta.json'
;; and downloaded image assets are stored.
;;
;; Variable: etaf-web-download-images (default t)
;; Whether `etaf-web-open' downloads and caches images locally into each page's
;; `assets/' directory (capped at 5 MB per image and 30 images per page).  When
;; nil, remote image URLs remain untouched and render as placeholder cards.
;;
;; Variable: etaf-web-fetch-timeout (default 30)
;; Timeout in seconds (integer or float) for HTTP(S) fetches performed by
;; `etaf-web-open'.
;;
;; Variable: etaf-web-render-command (default nil)
;; Program used to render a page whose content a script builds.  nil
;; auto-detects a Chromium-based browser, the symbol `off' skips rendering, and
;; a string names the executable.  When a page compiles to no prose and a
;; browser is available, `etaf-web-open' renders it headlessly and compiles the
;; rendered DOM.
;;
;; Variable: etaf-web-render-timeout (default 25)
;; Seconds to wait for that headless render before the page shows its notice.
;;
;; Error: etaf-web-error
;; Invalid HTML input, missing libxml support, unreadable source file or HTTP
;; fetch failure.  Catch this condition with `condition-case'.

;;; Code:

(defgroup etaf-web nil
  "Compile web pages to etaf-md reading views."
  :group 'hypermedia)

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf)
(require 'etaf-ui)
(require 'etaf-md)
(require 'etaf-web-compile)
(require 'etaf-web-cache)
(require 'etaf-web-views)
(require 'etaf-web-app)

(provide 'etaf-web)
;;; etaf-web.el ends here
