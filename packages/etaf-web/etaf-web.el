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
;; opens the resulting reading view through `etaf-md'.
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
;; handler attributes and dangerous link schemes, extracts the primary article
;; content and YAML front matter, resolves relative links and images against
;; BASE-URL when supplied, and emits normalized Markdown plus `:::' containers.
;; Signals `etaf-web-error' if HTML is not a string or Emacs lacks libxml.
;;
;; Function: etaf-web-open (source &optional other-window)
;;;###autoload (autoload 'etaf-web-open "etaf-web" nil t)
;; Open a web page or local HTML file SOURCE in an `etaf-md' preview buffer.
;; SOURCE is either a local HTML file path (or `file://' URL) or an `http://'
;; / `https://' URL.  Reads or fetches the page, compiles it to `index.md'
;; inside `etaf-web-cache-directory', optionally downloads bounded image assets
;; when `etaf-web-download-images' is non-nil, and opens the preview via
;; `etaf-md'.  Reuses an existing cached `index.md' for repeated opens of the
;; same HTTP(S) URL.  With OTHER-WINDOW non-nil, displays the preview in
;; another window.  Returns the preview buffer; signals `etaf-web-error' on
;; unreadable input or fetch failure.
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

(require 'etaf-md)
(require 'etaf-web-compile)
(require 'etaf-web-cache)
(require 'etaf-web-app)

(provide 'etaf-web)
;;; etaf-web.el ends here
