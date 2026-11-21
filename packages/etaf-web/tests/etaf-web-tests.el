;;; etaf-web-tests.el --- Public API acceptance tests for etaf-web -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public API behavior scenarios for `etaf-web'.  Every test exercises only
;; declared public interfaces (`etaf-web-to-markdown', `etaf-web-open',
;; `etaf-web-cache-directory', `etaf-web-download-images', `etaf-web-error')
;; and observable on-disk cache artifacts (`index.md', `source.html',
;; `meta.json', `assets/').

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)
(require 'etaf-md)
(require 'etaf-web)

(defconst etaf-web-tests--fixtures-dir
  (expand-file-name
   "fixtures"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing offline HTML and image fixtures.")

(defun etaf-web-tests--fixture (name)
  "Return absolute path of fixture NAME."
  (expand-file-name name etaf-web-tests--fixtures-dir))

(defun etaf-web-tests--read-file (path)
  "Return UTF-8 text of file PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun etaf-web-tests--make-http-buffer (headers body-bytes)
  "Create an unibyte HTTP response buffer with HEADERS and BODY-BYTES."
  (let ((buf (generate-new-buffer " *etaf-web-test-http*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert headers "\r\n\r\n")
      (insert body-bytes))
    buf))

(defun etaf-web-tests--cached-page-dirs (cache-root)
  "Return list of page directories created under CACHE-ROOT/pages/."
  (let ((pages (expand-file-name "pages" cache-root)))
    (when (file-directory-p pages)
      (cl-remove-if-not
       #'file-directory-p
       (directory-files pages t "\\`[^.]")))))

(ert-deftest etaf-web-tests-article-ir-elements ()
  "Article fixture compiles front matter, headings, inline runs, code and footnotes."
  (let* ((html (etaf-web-tests--read-file (etaf-web-tests--fixture "article.html")))
         (md (etaf-web-to-markdown
              html :base-url "https://example.com/posts/renderer/index.html")))
    ;; YAML front matter.
    (should (string-prefix-p "---\n" md))
    (should (string-match-p "^title: Building Text Renderers in Emacs$" md))
    (should (string-match-p "^author: Ada Lovelace$" md))
    (should (string-match-p "^date: \"2026-03-15\"\\|^date: 2026-03-15$" md))
    (should (string-match-p "^site: ETAF Engineering$" md))
    ;; Leading h1 matching front matter title is omitted; lower headings remain.
    (should-not (string-match-p "^# Building Text Renderers in Emacs$" md))
    (should (string-match-p "^## Architecture Overview$" md))
    (should (string-match-p "^### Task Checklist and Nesting$" md))
    (should (string-match-p "Line one\\\\\nLine two" md))
    ;; Inline styles including etaf dialect and dynamic code-span backtick fencing.
    (should (string-match-p "\\*italic\\*" md))
    (should (string-match-p "\\*\\*bold\\*\\*" md))
    (should (string-match-p "~~old~~" md))
    (should (string-match-p "==highlighted==" md))
    (should (string-match-p ":kbd\\[Ctrl\\+C\\]" md))
    (should (string-match-p "H~2~O" md))
    (should (string-match-p "2\\^10\\^" md))
    (should (string-match-p "```use ``foo`` inside```" md))
    ;; Link resolution and #anchor preservation.
    (should (string-match-p
             "\\[relative guide\\](https://example\\.com/posts/renderer/guide/layout\\.html)"
             md))
    (should (string-match-p "\\[external spec\\](https://example\\.org/spec)" md))
    (should (string-match-p "\\[local jump\\](#architecture-overview)" md))
    (should (string-match-p
             "\\[stay\\](#raw-anchor)"
             (etaf-web-to-markdown
              "<p><a href=\"#raw-anchor\">stay</a></p>"
              :base-url "https://example.com/posts/1/")))
    ;; Picture picks first decodable source (png over avif); figcaption becomes alt.
    (should (string-match-p
             "!\\[Figure 1: Rendering pipeline stages\\.\\](https://example\\.com/posts/renderer/sample\\.png)"
             md))
    (should-not (string-match-p "\\*Figure 1: Rendering pipeline stages\\.\\*" md))
    ;; Fenced code block with language tag.
    (should (string-match-p "```elisp\n(defun render-box (node)" md))
    ;; Task checkboxes and 2-space nested ordered list.
    (should (string-match-p "^- \\[x\\] Parse HTML with libxml$" md))
    (should (string-match-p "^- \\[ \\] Add TOC drawer later$" md))
    (should (string-match-p "^  1\\. Design SVG first$" md))
    (should (string-match-p "^  2\\. Verify in GUI$" md))
    ;; Definition list, blockquote and hr.
    (should (string-match-p "^IR\n: Text-level Markdown plus container blocks\\.$" md))
    (should (string-match-p "^> Keep the core small and predictable\\.$" md))
    (should (string-match-p "^---$" md))
    ;; Footnote refs and definitions at end.
    (should (string-match-p "pure\\[\\^1\\] and predictable\\[\\^2\\]" md))
    (should (string-match-p "^\\[\\^1\\]: Purity makes offline snapshot testing trivial\\.$" md))
    (should (string-match-p "^\\[\\^2\\]: Predictable row counts prevent cursor jitter\\.$" md))
    ;; Trailing whitespace stripped, no double blank lines, single trailing newline.
    (should (string-suffix-p "\n" md))
    (should-not (string-suffix-p "\n\n" md))
    (should-not (string-match-p "[ \t]+$" md))
    (should-not (string-match-p "\n\n\n" md))))

(ert-deftest etaf-web-tests-boilerplate-and-density-extraction ()
  "Page chrome is pruned and density fallback selects the main content block."
  (let* ((article-md (etaf-web-to-markdown
                      (etaf-web-tests--read-file
                       (etaf-web-tests--fixture "article.html"))))
         (density-md (etaf-web-to-markdown
                      (etaf-web-tests--read-file
                       (etaf-web-tests--fixture "fallback-density.html")))))
    ;; Article chrome pruned.
    (dolist (noise '("Home Nav Link" "Buy Super Widgets" "Sidebar Trending Noise"
                     "Share on Mastodon" "Subscribe to our weekly"
                     "Related post noise" "User comment noise" "Footer Noise"))
      (should-not (string-match-p (regexp-quote noise) article-md)))
    ;; Density fallback extracts main content div and drops chrome.
    (should (string-match-p "^# Density Extraction Works Without Semantic Landmarks$"
                            density-md))
    (should (string-match-p "```python\ndef score(text_len, link_len):" density-md))
    (should (string-match-p "^:::details {title=\"Why Density Scoring\" open=true}$"
                            density-md))
    (dolist (noise '("Link A" "Side 1" "Sponsored banner" "Reader comment block"))
      (should-not (string-match-p (regexp-quote noise) density-md)))))

(ert-deftest etaf-web-tests-details-callouts-and-tables ()
  "Details, callouts, spanned tables and fallback fences compile cleanly."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "docs-containers.html")))
         (md (etaf-web-to-markdown html)))
    ;; Callout containers.
    (should (string-match-p "^:::tip {title=\"Quick Start\"}\nRun `make check`" md))
    (should (string-match-p "^:::warning\nCache keys include" md))
    (should (string-match-p "^:::danger {title=\"Breaking Change\"}" md))
    (should (string-match-p "^:::note\nStandalone ARIA note block\\.$" md))
    ;; Details containers preserve open=true and open=false.
    (should (string-match-p
             "^:::details {title=\"Expanded Build Details\" open=true}\nEmacs 29\\.1"
             md))
    (should (string-match-p
             "^:::details {title=\"Collapsed Troubleshooting\" open=false}\nDelete the page"
             md))
    ;; Table expands colspan/rowspan, escapes pipe, joins multi-block cell with ；.
    (should (string-match-p "^| Platform | Platform | Notes |$" md))
    (should (string-match-p "^| --- | --- | --- |$" md))
    (should (string-match-p "^| Unix | macOS | Uses a\\\\|b pipe；Verified locally |$" md))
    (should (string-match-p "^| Unix | Linux | Standard GTK build |$" md))
    ;; Language-less pre>code falls back to `text'.
    (should (string-match-p "```text\nplain output without language class" md))
    ;; Nav and footer pruned.
    (should-not (string-match-p "Docs Home" md))
    (should-not (string-match-p "Docs Footer Noise" md))))

(ert-deftest etaf-web-tests-sanitizes-dangerous-tags-and-links ()
  "Unsafe tags, event handlers and dangerous link schemes are stripped."
  (let* ((html (etaf-web-tests--read-file (etaf-web-tests--fixture "article.html")))
         (md (etaf-web-to-markdown html)))
    (dolist (forbidden '("evil-script-payload" "must be stripped" "INLINE_SVG_NOISE"
                         "IFRAME_NOISE" "NOSCRIPT_NOISE" "TEMPLATE_NOISE"
                         "stealCookies" "javascript:" "vbscript:" "data:text/html"
                         "Evil JS Link" "Evil VBS Link" "Evil Data Link"))
      (should-not (string-match-p (regexp-quote forbidden) md)))))

(ert-deftest etaf-web-tests-open-local-fixture-renders-in-buffer ()
  "Opening a local fixture renders title, code and caption in preview buffer."
  (let* ((cache-root (make-temp-file "etaf-web-local-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images t)
         (fixture (etaf-web-tests--fixture "article.html"))
         (buf nil))
    (unwind-protect
        (progn
          (setq buf (etaf-web-open fixture))
          (should (buffer-live-p buf))
          (let ((painted (with-current-buffer buf
                           (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Building Text Renderers in Emacs" painted))
            (should (string-match-p "defun render-box" painted))
            (should (string-match-p "Figure 1: Rendering pipeline stages\\." painted)))
          ;; Local cache directory holds index.md, source.html, meta.json and copied asset.
          (let* ((dirs (etaf-web-tests--cached-page-dirs cache-root))
                 (page-dir (car dirs))
                 (index-md (and page-dir
                                (etaf-web-tests--read-file
                                 (expand-file-name "index.md" page-dir)))))
            (should (= (length dirs) 1))
            (should (file-readable-p (expand-file-name "source.html" page-dir)))
            (should (file-readable-p (expand-file-name "meta.json" page-dir)))
            (should (string-match-p
                     "!\\[Figure 1: Rendering pipeline stages\\.\\](assets/[0-9a-f]+\\.png)"
                     index-md))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-url-fetch-caches-and-skips-refetch ()
  "Stubbed HTTP fetch decodes charset, caches files and skips second fetch."
  (let* ((cache-root (make-temp-file "etaf-web-http-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images t)
         (page-url "https://docs.example.test/guide/start.html")
         (img-url "https://docs.example.test/guide/hero.png")
         (png-bytes (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally
                       (etaf-web-tests--fixture "sample.png"))
                      (buffer-string)))
         (gbk-html (encode-coding-string
                    (concat "<!DOCTYPE html><html><head>"
                            "<meta charset=\"gbk\">"
                            "<title>中文指南</title></head>"
                            "<body><article><h1>中文指南</h1>"
                            "<p>正文内容与图片：</p>"
                            "<figure><img src=\"hero.png\" alt=\"示意图\">"
                            "<figcaption>图 1 架构</figcaption></figure>"
                            "<img src=\"missing.png\" alt=\"缺失图\">"
                            "</article></body></html>")
                    'gb18030))
         (fetch-log nil)
         (buf1 nil)
         (buf2 nil))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &rest _args)
                     (push url fetch-log)
                     (cond
                      ((equal url page-url)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nETag: \"v1\""
                        gbk-html))
                      ((equal url img-url)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 200 OK\r\nContent-Type: image/png"
                        png-bytes))
                      (t
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain"
                        "not found"))))))
          ;; First open: fetches HTML + two images (one succeeds, one 404s gracefully).
          (setq buf1 (etaf-web-open page-url))
          (should (buffer-live-p buf1))
          (let ((painted (with-current-buffer buf1
                           (buffer-substring-no-properties (point-min) (point-max))))
                (first-fetches (length fetch-log)))
            (should (string-match-p "中文指南" painted))
            (should (string-match-p "图 1 架构" painted))
            (should (= first-fetches 3))
            ;; Verify cache artifacts on disk.
            (let* ((dirs (etaf-web-tests--cached-page-dirs cache-root))
                   (page-dir (car dirs))
                   (index-md (etaf-web-tests--read-file
                              (expand-file-name "index.md" page-dir)))
                   (meta (json-parse-string
                          (etaf-web-tests--read-file
                           (expand-file-name "meta.json" page-dir))
                          :object-type 'alist)))
              (should (= (length dirs) 1))
              (should (equal (alist-get 'url meta) page-url))
              (should (equal (alist-get 'title meta) "中文指南"))
              (should (equal (alist-get 'etag meta) "\"v1\""))
              ;; Successful image rewritten to assets/ with figcaption as alt.
              (should (string-match-p "!\\[图 1 架构\\](assets/[0-9a-f]+\\.png)" index-md))
              (should-not (string-match-p "\\*图 1 架构\\*" index-md))
              (should (string-match-p
                       "!\\[缺失图\\](https://docs\\.example\\.test/guide/missing\\.png)"
                       index-md)))
            (with-current-buffer buf1 (etaf-md-close))
            (setq buf1 nil)
            ;; Second open of the same URL hits index.md cache with zero fetches.
            (setq buf2 (etaf-web-open page-url))
            (should (buffer-live-p buf2))
            (should (= (length fetch-log) first-fetches))
            (let ((painted2 (with-current-buffer buf2
                              (buffer-substring-no-properties (point-min) (point-max)))))
              (should (string-match-p "中文指南" painted2)))))
      (when (buffer-live-p buf1)
        (with-current-buffer buf1 (etaf-md-close)))
      (when (buffer-live-p buf2)
        (with-current-buffer buf2 (etaf-md-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-disable-image-downloads-and-error-conditions ()
  "Disabling image downloads keeps remote URLs; bad inputs signal errors."
  (let* ((cache-root (make-temp-file "etaf-web-noimg-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images nil)
         (page-url "https://example.test/no-images.html")
         (fetched nil)
         (buf nil))
    (unwind-protect
        (progn
          (should-error (etaf-web-to-markdown 123) :type 'etaf-web-error)
          (should-error (etaf-web-open "/nonexistent/etaf-web-missing.html")
                        :type 'etaf-web-error)
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (url &rest _args)
                       (push url fetched)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8"
                        "<article><h1>No DL</h1><img src=\"pic.png\" alt=\"Pic\"></article>"))))
            (setq buf (etaf-web-open page-url))
            (should (equal fetched (list page-url)))
            (let* ((page-dir (car (etaf-web-tests--cached-page-dirs cache-root)))
                   (index-md (etaf-web-tests--read-file
                              (expand-file-name "index.md" page-dir))))
              (should (string-match-p
                       "!\\[Pic\\](https://example\\.test/pic\\.png)" index-md)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-http-link-navigation-and-anchor-jump ()
  "Activating an HTTP link opens it via `etaf-web-open'; `#anchor' jumps locally."
  (let* ((cache-root (make-temp-file "etaf-web-nav-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images nil)
         (url-a "https://nav.example.test/a.html")
         (url-b "https://nav.example.test/b.html")
         (browsed nil)
         (buf nil))
    (unwind-protect
        (cl-letf (((symbol-function 'browse-url)
                   (lambda (u &rest _) (push u browsed)))
                  ((symbol-function 'url-retrieve-synchronously)
                   (lambda (url &rest _args)
                     (cond
                      ((equal url url-a)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8"
                        (concat "<article><h1>Page Alpha</h1>"
                                "<p><a href=\"#sec-end\">Jump Down</a> and "
                                "<a href=\"b.html\">Next Page</a>.</p>"
                                "<h2 id=\"sec-end\">Section End</h2></article>")))
                      ((equal url url-b)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8"
                        "<article><h1>Page Beta</h1><p>Arrived on Beta.</p></article>"))
                      (t
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain"
                        "missing"))))))
          (setq buf (etaf-web-open url-a))
          (with-current-buffer buf
            ;; `#anchor' link resolves HTML heading id and jumps in-document.
            (goto-char (point-min))
            (should (search-forward "Jump Down" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET")))
            (should (looking-at-p "Section End"))
            ;; HTTP link routes back into etaf-web-open instead of browse-url.
            (goto-char (point-min))
            (should (search-forward "Next Page" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET"))))
          (let* ((current (current-buffer))
                 (painted (with-current-buffer current
                            (buffer-substring-no-properties (point-min) (point-max)))))
            (setq buf current)
            (should (string-match-p "Page Beta" painted))
            (should (string-match-p "Arrived on Beta\\." painted))
            (should-not browsed)))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close)))
      (delete-directory cache-root t))))

(defun etaf-web-tests--count-occurrences (needle haystack)
  "Return non-overlapping occurrence count of NEEDLE in HAYSTACK."
  (let ((count 0)
        (pos 0))
    (while (setq pos (string-search needle haystack pos))
      (setq count (1+ count)
            pos (+ pos (length needle))))
    count))

(ert-deftest etaf-web-tests-deduplicates-leading-h1-only ()
  "Leading h1 matching front-matter title is omitted while later h1s stay."
  (let* ((single-html
          (concat "<html><head><title>  ETAF   Web Guide  </title></head>"
                  "<body><article><header><h1><strong>ETAF</strong> "
                  "<em>Web</em>   Guide</h1></header>"
                  "<p>Intro paragraph.</p></article></body></html>"))
         (single-md (etaf-web-to-markdown single-html))
         (multi-html
          (concat "<html><head><title>Same Title</title></head>"
                  "<body><article><h1>Same Title</h1>"
                  "<p>Opening body.</p>"
                  "<h1>Same Title</h1>"
                  "<p>Middle body.</p>"
                  "<h1>Closing Heading</h1>"
                  "</article></body></html>"))
         (multi-md (etaf-web-to-markdown multi-html)))
    ;; Single matching leading h1: title appears only once (in front matter).
    (should (= (etaf-web-tests--count-occurrences "ETAF Web Guide" single-md) 1))
    (should-not (string-match-p "^# " single-md))
    ;; Leading h1 dropped, while middle duplicate h1 and ending h1 remain.
    (should (string-match-p "---\n\nOpening body\\." multi-md))
    (should (= (etaf-web-tests--count-occurrences "# Same Title" multi-md) 1))
    (should (string-match-p "^# Closing Heading$" multi-md))))

(ert-deftest etaf-web-tests-figure-figcaption-replaces-alt-without-extra-paragraph ()
  "Image figures use figcaption plain text as alt and emit no extra caption."
  (let* ((html
          (concat "<article>"
                  "<figure><img src=\"pipe.png\" alt=\"流水线\">"
                  "<figcaption>图 1：<strong>抓取</strong> → <em>编译</em> → ETAF 渲染</figcaption>"
                  "</figure>"
                  "<figure><img src=\"solo.png\" alt=\"无图注保留原值\"></figure>"
                  "</article>"))
         (md (etaf-web-to-markdown html :base-url "https://example.com/demo/")))
    ;; Figure with figcaption: single image ref, alt = plain figcaption, no italic line.
    (should (string-match-p
             "^!\\[图 1：抓取 → 编译 → ETAF 渲染\\](https://example\\.com/demo/pipe\\.png)$"
             md))
    (should-not (string-match-p "流水线" md))
    (should-not (string-match-p "\\*图 1" md))
    (should (= (etaf-web-tests--count-occurrences "pipe.png" md) 1))
    ;; Figure without figcaption keeps original alt.
    (should (string-match-p
             "^!\\[无图注保留原值\\](https://example\\.com/demo/solo\\.png)$"
             md))))

(provide 'etaf-web-tests)
;;; etaf-web-tests.el ends here
