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
              "<p>Jump to <a href=\"#raw-anchor\">stay</a> section.</p>"
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
            ;; Second open reuses index.md: the page and the saved image are
            ;; not fetched again.  Only the image that failed may be retried,
            ;; so a later success can still be cached.
            (setq buf2 (etaf-web-open page-url))
            (should (buffer-live-p buf2))
            (should (= (cl-count page-url fetch-log :test #'equal) 1))
            (should (= (cl-count img-url fetch-log :test #'equal) 1))
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

(ert-deftest etaf-web-tests-fetch-timeout-and-distinct-errors ()
  "`etaf-web-fetch-timeout' is passed to fetcher; HTTP, timeout and connection errors differ."
  (let* ((cache-root (make-temp-file "etaf-web-timeout-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images nil)
         (etaf-web-fetch-timeout 42.5)
         (sample-html (etaf-web-tests--read-file
                       (etaf-web-tests--fixture "mdn-fetch-snippet.html")))
         (seen-timeout nil)
         (buf nil))
    (unwind-protect
        (progn
          ;; 1. Passes `etaf-web-fetch-timeout' through to `url-retrieve-synchronously'.
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (_url _silent _inhibit timeout)
                       (setq seen-timeout timeout)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8"
                        sample-html))))
            (setq buf (etaf-web-open "https://docs.example.test/api/fetch"))
            (should (eql seen-timeout 42.5))
            (when (buffer-live-p buf)
              (with-current-buffer buf (etaf-md-close))
              (setq buf nil)))
          ;; 2. HTTP 403 reports status code distinctly.
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (etaf-web-tests--make-http-buffer
                        "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html"
                        "<h1>Forbidden</h1>"))))
            (let ((err (should-error
                        (etaf-web-open "https://docs.example.test/forbidden")
                        :type 'etaf-web-error)))
              (should (string-match-p "403" (error-message-string err)))))
          ;; 3. Timeout (nil return) reports timeout distinctly from connection failure.
          (let ((timeout-msg nil)
                (conn-msg nil))
            (cl-letf (((symbol-function 'url-retrieve-synchronously)
                       (lambda (&rest _) nil)))
              (let ((err (should-error
                          (etaf-web-open "https://docs.example.test/slow")
                          :type 'etaf-web-error)))
                (setq timeout-msg (error-message-string err))))
            (cl-letf (((symbol-function 'url-retrieve-synchronously)
                       (lambda (&rest _)
                         (signal 'file-error '("Connection refused")))))
              (let ((err (should-error
                          (etaf-web-open "https://docs.example.test/down")
                          :type 'etaf-web-error)))
                (setq conn-msg (error-message-string err))))
            (should (string-match-p "Timed out" timeout-msg))
            (should (string-match-p "42\\.5" timeout-msg))
            (should (string-match-p "Connection failed" conn-msg))
            (should-not (equal timeout-msg conn-msg))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-md-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-strips-makeinfo-nav-and-permalinks ()
  "Makeinfo Next/Previous/Up nav, bracket nav, adjacent hr and `[¶]` markers are stripped."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "gnu-makeinfo.html")))
         (md (etaf-web-to-markdown
              html
              :base-url "https://docs.example.test/manual/Keyboard-Macros.html")))
    ;; Nav panels, bracket-only nav lines and trailing makeinfo nav are dropped.
    (should-not (string-match-p "Next:" md))
    (should-not (string-match-p "Previous:" md))
    (should-not (string-match-p "File Handling" md))
    (should-not (string-match-p "\\[Contents\\]" md))
    (should-not (string-match-p "\\[Index\\]" md))
    ;; Heading permalink markers `[¶]' are stripped; clean headings remain.
    (should-not (string-match-p "¶" md))
    (should (string-match-p "^## 19 Keyboard Macros$" md))
    (should (string-match-p "^### Basic Use$" md))
    ;; Leading decorative hr after nav is dropped; body starts with heading.
    (should (string-match-p "---\n\n## 19 Keyboard Macros$" md))
    ;; Mid-article real hr stays intact.
    (should (string-match-p "conveniently later\\.\n\n---\n\nA keyboard macro" md))))

(ert-deftest etaf-web-tests-strips-breadcrumbs-and-anchor-noise ()
  "Breadcrumbs (class/nav/link-trail) and short `#anchor' paragraphs are dropped."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "breadcrumb-news.html")))
         (md (etaf-web-to-markdown
              html :base-url "https://www.example.com/0/750/000.htm")))
    ;; Both class-based and link-trail breadcrumbs are dropped.
    (should-not (string-match-p "站点" md))
    (should-not (string-match-p "游戏之家" md))
    (should-not (string-match-p "游戏快报" md))
    ;; Short `#anchor'-only decorative paragraphs are dropped.
    (should-not (string-match-p "评论：" md))
    (should-not (string-match-p "#post_comm" md))
    (should-not (string-match-p "返回顶部" md))
    ;; Real prose, inline `#anchor' links and headings stay intact.
    (should (string-match-p "^title: Steam 2024 年远程同乐游戏节公布$" md))
    (should (string-match-p "\\[活动时间\\](#活动时间)" md))
    (should (string-match-p "^## 活动时间$" md))
    (should (string-match-p "支持与好友远程联机" md))))

(ert-deftest etaf-web-tests-lazy-images-and-srcset-max-width ()
  "Lazy-load attributes override placeholder `src' and `srcset' picks max width."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "lazy-images.html")))
         (md (etaf-web-to-markdown html :base-url "https://img.example.com/post/")))
    ;; `data-src' and `data-original' override `v2/t.png' placeholder.
    (should-not (string-match-p "v2/t\\.png" md))
    (should (string-match-p
             "!\\[Real photo\\](https://img\\.example\\.com/uploads/real-photo\\.png)"
             md))
    (should (string-match-p
             "!\\[Original photo\\](https://img\\.example\\.com/uploads/orig\\.png\\?x-bce-process=image/format,f_auto)"
             md))
    ;; `srcset' picks the widest (1600w) candidate even with comma in query.
    (should (string-match-p
             "!\\[Responsive hero\\](https://img\\.example\\.com/post/huge-1600\\.jpg\\?f=auto,q=80)"
             md))
    (should-not (string-match-p "small-400\\.jpg\\|fallback-300\\.jpg" md))
    ;; `<picture><source srcset>' picks widest decodable png (1400w over 600w/avif).
    (should (string-match-p
             "!\\[Picture widest decodable source\\](https://img\\.example\\.com/post/hero-1400\\.png)"
             md))))

(ert-deftest etaf-web-tests-prunes-site-tail-noise-without-false-positives ()
  "Site tail noise is dropped while normal prose mentioning keywords/sharing stays."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "tail-noise.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/news/1")))
    ;; Tail noise blocks all removed.
    (dolist (noise '("广告声明" "投诉水文" "我要纠错" "分享到QQ" "分享到微信"
                     "下载客户端APP" "下载本站APP" "链接一" "相关文章"
                     "相关新闻一" "关键词：" "推荐阅读" "猜你喜欢"))
      (should-not (string-match-p (regexp-quote noise) md)))
    ;; Real prose mentioning 关键词 and 分享 stays intact.
    (should (string-match-p "围绕关键词检索展开，并分享我们在实际项目" md))
    (should (string-match-p "活动持续一周" md))))

(ert-deftest etaf-web-tests-deduplicates-title-with-site-suffix-and-prefix ()
  "Leading h1 deduplication handles site suffixes, prefixes and keeps mid-body h1."
  (let* ((mdn-md (etaf-web-to-markdown
                  (etaf-web-tests--read-file
                   (etaf-web-tests--fixture "title-suffixes.html"))))
         (prefix-md (etaf-web-to-markdown
                     (concat "<html><head><title>Fetch API Complete Reference</title></head>"
                             "<body><article><h1>Fetch API</h1><p>Body.</p></article></body></html>")))
         (underscore-md (etaf-web-to-markdown
                         (concat "<html><head><title>深度解析_技术专栏</title></head>"
                                 "<body><article><h1>深度解析</h1><p>正文。</p></article></body></html>"))))
    ;; MDN-style suffix stripped: leading h1 removed, mid-body h1 preserved.
    (should (string-match-p "^title: Fetch API - Web APIs | MDN$" mdn-md))
    (should (string-match-p "---\n\nThe Fetch API provides" mdn-md))
    (should (= (etaf-web-tests--count-occurrences "# Fetch API" mdn-md) 1))
    (should (string-match-p "^# Fetch API\n\nMid-body h1" mdn-md))
    ;; Prefix match removes leading h1.
    (should-not (string-match-p "^# Fetch API$" prefix-md))
    (should (string-match-p "Body\\." prefix-md))
    ;; Underscore suffix stripped.
    (should-not (string-match-p "^# 深度解析$" underscore-md))
    (should (string-match-p "正文。" underscore-md))))

(ert-deftest etaf-web-tests-normalizes-front-matter-dates ()
  "ISO timestamps, slash dates and year-month normalize to YYYY-MM-DD; unknown stays raw."
  (let ((iso-md (etaf-web-to-markdown
                 (etaf-web-tests--read-file
                  (etaf-web-tests--fixture "title-suffixes.html"))))
        (slash-md (etaf-web-to-markdown
                   "<html><head><meta name=\"date\" content=\"2026/6/8\"><title>A</title></head><body><p>x</p></body></html>"))
        (ym-md (etaf-web-to-markdown
                "<html><head><meta name=\"date\" content=\"2026-6\"><title>B</title></head><body><p>x</p></body></html>"))
        (raw-md (etaf-web-to-markdown
                 "<html><head><meta name=\"date\" content=\"Spring 2026\"><title>C</title></head><body><p>x</p></body></html>")))
    (should (string-match-p "^date: 2026-06-08$" iso-md))
    (should-not (string-match-p "T12:44:07" iso-md))
    (should (string-match-p "^date: 2026-06-08$" slash-md))
    (should (string-match-p "^date: 2026-06-01$" ym-md))
    (should (string-match-p "^date: Spring 2026$" raw-md))))

(ert-deftest etaf-web-tests-cleans-overlong-and-title-duplicate-image-alt ()
  "Overlong (>60 chars) and title-duplicate alts become empty; short alt and figcaption stay."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "image-alt-cleanup.html")))
         (md (etaf-web-to-markdown html)))
    (should (string-match-p "!\\[\\](https://img\\.example\\.com/same-title\\.png)" md))
    (should (string-match-p "!\\[\\](https://img\\.example\\.com/too-long\\.png)" md))
    (should (string-match-p
             "!\\[Architecture overview\\](https://img\\.example\\.com/short\\.png)"
             md))
    (should (string-match-p
             "!\\[Figure 2: A detailed caption that intentionally exceeds sixty characters is still preserved from figcaption\\](https://img\\.example\\.com/fig\\.png)"
             md))))

(ert-deftest etaf-web-tests-card-grids-to-columns-and-cards ()
  "3-card, 5-card (3+2 split) and classless grids compile to columns + cards and render."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-cards.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; 3-card feature grid -> single 3-column block with resolved hrefs.
    (should (string-match-p
             "^:::columns {columns=\"3\" min-width=\"22ch\" divider=false}$"
             md))
    (should (string-match-p
             "^:::card {title=\"Fast Parser\" href=\"https://example\\.com/docs/parse\"}\nParses HTML directly"
             md))
    (should (string-match-p
             "^:::card {title=\"Grid Layout\" href=\"https://example\\.org/layout\"}\nPreserves multi-column"
             md))
    (should (string-match-p
             "^:::card {title=\"Offline Cache\"}\nStores readable Markdown"
             md))
    ;; 5-card catalog splits into 3 + 2 columns blocks.
    (should (string-match-p
             (concat ":::columns {columns=\"3\" min-width=\"22ch\" divider=false}\n"
                     ":::col\n:::card {title=\"Card One\"}")
             md))
    (should (string-match-p
             (concat ":::columns {columns=\"2\" min-width=\"22ch\" divider=false}\n"
                     ":::col\n:::card {title=\"Card Four\"}")
             md))
    (should (string-match-p "^:::card {title=\"Card Five\"}$" md))
    ;; Classless 2-card grid maps to 2-column block.
    (should (string-match-p "^:::card {title=\"Compact Footprints\"}$" md))
    (should (string-match-p "^:::card {title=\"Keyboard First\"}\nNavigate every link" md))
    ;; Verify compiled IR renders cleanly in etaf-md with zero validation errors.
    (let* ((session (etaf-md-create :text md))
           (buf (etaf-md-open session)))
      (unwind-protect
          (let ((painted (with-current-buffer buf
                           (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Fast Parser" painted))
            (should (string-match-p "Card Five" painted))
            (should (string-match-p "Keyboard First" painted))
            (should-not (string-match-p "is not an attribute\\|is required\\|is not a child"
                                        painted)))
        (when (buffer-live-p buf)
          (with-current-buffer buf (etaf-md-close)))))))

(ert-deftest etaf-web-tests-docs-tabs-to-tabs-container ()
  "ARIA tablist+tabpanel (including hidden panels) and class-based tabs map to :::tabs."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-tabs.html")))
         (md (etaf-web-to-markdown html)))
    ;; ARIA tablist matches panels by aria-controls despite DOM order and keeps hidden panels.
    (should (string-match-p
             (concat "^:::tabs\n"
                     "@tab {title=\"npm\"}\n```sh\nnpm install etaf-demo\n```\n\n"
                     "@tab {title=\"pnpm\" selected=true}\n```sh\npnpm add etaf-demo\n```\n\n"
                     "@tab {title=\"yarn\"}\n```sh\nyarn add etaf-demo\n```\n:::$")
             md))
    ;; Class-based code-tabs container also compiles to :::tabs.
    (should (string-match-p
             (concat "@tab {title=\"Emacs Lisp\" selected=true}\n```elisp\n"
                     "(etaf-web-open \"https://example\\.com\")\n```\n\n"
                     "@tab {title=\"Shell\"}\n```sh\nmake -C packages/etaf-web check\n```")
             md))
    ;; Verify compiled IR renders cleanly in etaf-md.
    (let* ((session (etaf-md-create :text md))
           (buf (etaf-md-open session)))
      (unwind-protect
          (let ((painted (with-current-buffer buf
                           (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "npm" painted))
            (should (string-match-p "pnpm add etaf-demo" painted))
            (should (string-match-p "Emacs Lisp" painted))
            (should-not (string-match-p "is not an attribute\\|is required\\|is not a child"
                                        painted)))
        (when (buffer-live-p buf)
          (with-current-buffer buf (etaf-md-close)))))))

(ert-deftest etaf-web-tests-steps-and-timeline-containers ()
  "Steps/stepper/how-it-works and timeline containers compile to :::steps and :::timeline."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-steps-timeline.html")))
         (md (etaf-web-to-markdown html)))
    ;; Section heading preserved before :::steps; redundant `1.' prefix stripped.
    (should (string-match-p "^## How It Works\n\n:::steps {list-style=\"decimal\"}$" md))
    (should (string-match-p
             "^:::step {title=\"Fetch Page\"}\nDownload HTML over HTTP(S)"
             md))
    (should (string-match-p "^:::step {title=\"Compile to IR\"}$" md))
    (should (string-match-p "^:::step {title=\"Render Buffer\"}$" md))
    ;; Stepper with badge spans strips badge from body.
    (should (string-match-p "^:::step {title=\"Clone Workspace\"}\nCheck out the repository" md))
    (should (string-match-p "^:::step {title=\"Run Checks\"}\nExecute `make -C packages/etaf-web check`" md))
    ;; Timeline maps <time> to time="..." attribute on :::event.
    (should (string-match-p
             (concat "^:::timeline\n"
                     ":::event {title=\"Initial Compiler\" time=\"2026-01\"}\n"
                     "Added libxml sanitization and article extraction\\.\n:::\n"
                     ":::event {title=\"Layout Containers\" time=\"2026-04\"}\n"
                     "Mapped card grids, docs tabs, steps and timelines\\.\n:::\n:::$")
             md))
    ;; Verify compiled IR renders cleanly in etaf-md.
    (let* ((session (etaf-md-create :text md))
           (buf (etaf-md-open session)))
      (unwind-protect
          (let ((painted (with-current-buffer buf
                           (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Fetch Page" painted))
            (should (string-match-p "Clone Workspace" painted))
            (should (string-match-p "Initial Compiler" painted))
            (should (string-match-p "2026-04" painted))
            (should-not (string-match-p "is not an attribute\\|is required\\|is not a child"
                                        painted)))
        (when (buffer-live-p buf)
          (with-current-buffer buf (etaf-md-close)))))))

(ert-deftest etaf-web-tests-prose-lists-and-code-not-cards ()
  "Consecutive paragraphs, ordinary lists, code blocks and single-child wrappers stay flat."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-negative-prose.html")))
         (md (etaf-web-to-markdown html)))
    ;; None of the layout containers should trigger on ordinary prose/lists/code.
    (should-not (string-match-p ":::columns" md))
    (should-not (string-match-p ":::card" md))
    (should-not (string-match-p ":::col" md))
    (should-not (string-match-p ":::steps" md))
    (should-not (string-match-p ":::timeline" md))
    (should-not (string-match-p ":::tabs" md))
    ;; Original prose, lists, code and headings stay intact.
    (should (string-match-p "\\*\\*First point:\\*\\* Consecutive paragraphs" md))
    (should (string-match-p "^- \\*\\*Alpha\\*\\*: Regular unordered list" md))
    (should (string-match-p "^1\\. \\*\\*Step one\\*\\*: Plain ordered lists" md))
    (should (string-match-p "```elisp\n(\\+ 1 2)\n```" md))
    (should (string-match-p "^### Lonely Card$" md))
    (should (string-match-p "^## Long Section One$" md))
    (should (string-match-p "^### Unordered Note A$" md))))

(ert-deftest etaf-web-tests-inline-spacing-fidelity ()
  "Adjacent inline siblings preserve boundary whitespace without corrupting tight runs or code."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "inline-spacing.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; 1. Adjacent spans separated by newline collapse to one space.
    (should (string-match-p "^ETAF Emacs Text Application Framework$" md))
    (should-not (string-match-p "ETAFEmacs" md))
    ;; 2. Adjacent links separated by space (or minified) keep a single space.
    (should (string-match-p
             "^\\[Install ETAF\\](https://example\\.com/install) \\[GitHub\\](https://github\\.com/emacs-taf)$"
             md))
    (should-not (string-match-p ")\\[GitHub\\]" md))
    ;; 3. Tight adjacent unclassed elements add no spurious space.
    (should (string-match-p "^foobar and \\*un\\*known and hello,world\\.$" md))
    ;; 4. Inline code preserves internal spacing, respects outer spacing, no space before `.'.
    (should (string-match-p
             "^Run `make  check` now, tight`foo`bar, and `spaced`\\.$"
             md))
    ;; 5. Chinese/English boundary whitespace, plus a split `中En' joined with
    ;; one separating space, plus `<br>' preserved.
    (should (string-match-p "^中文 English 与 `ETAF` 文本，以及紧贴中 En。$" md))
    (should (string-match-p "^Line one\\\\\nLine two$" md))))

(ert-deftest etaf-web-tests-separates-cjk-and-latin-across-elements ()
  "A Chinese character next to a Latin letter or digit gets one separating space."
  (let* ((html (concat "<html><head><title>统计</title></head><body><article>"
                       "<p><span>约 2095 字</span><span>7 分钟</span></p>"
                       "<p><span>Vim</span><span>中文</span></p>"
                       "<p><span>字数</span><code>7</code></p>"
                       "<p>一段足够长的正文，用来保证这个页面不会被当成空壳页面处理，内容足够长足够长。</p>"
                       "</article></body></html>"))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; Digit after a Chinese character takes a space; so does a following ideograph.
    (should (string-match-p "^约 2095 字 7 分钟$" md))
    (should (string-match-p "^Vim 中文$" md))
    ;; An inline code span keeps its own boundary untouched.
    (should (string-match-p "^字数`7`$" md))
    (should-not (string-match-p "字7" md))))

(ert-deftest etaf-web-tests-strips-card-ordinal-keeps-prose-number ()
  "Decorative 1-3 digit leading ordinal is dropped inside cards; prose numbers stay."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "inline-spacing.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; Leading `01' / `02' inside feature cards are removed.
    (should (string-match-p
             "^:::card {title=\"Declarative components\"}\nCompose reusable Components"
             md))
    (should (string-match-p
             "^:::card {title=\"Incremental updates\"}\nRetained rendering publishes"
             md))
    (should-not (string-match-p "^01$" md))
    (should-not (string-match-p "^02$" md))
    ;; Standalone numeric paragraph in normal prose stays untouched.
    (should (string-match-p "^Answer to everything:\n\n42$" md))))

(ert-deftest etaf-web-tests-preserves-bounded-img-dimensions-and-drops-trackers ()
  "Bounded HTML image dimensions survive compilation, trackers drop, large photos stay Markdown."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "wrapper-sidebar-layout.html")))
         (md (etaf-web-to-markdown html :base-url "https://portal.example/")))
    ;; Bounded 52x52 icon preserves width/height in CommonMark HTML <img>.
    (should (string-match-p
             "<img src=\"https://portal\\.example/brand-icon\\.svg\" alt=\"\" width=\"52\" height=\"52\">"
             md))
    ;; Inline style max-width/max-height caps single axis (120px) to keep aspect ratio.
    (should (string-match-p
             "<img src=\"https://portal\\.example/thumb-large\\.png\" alt=\"示意图\" width=\"120\">"
             md))
    ;; 1x1 tracking pixel is dropped completely.
    (should-not (string-match-p "pixel\\.gif" md))
    ;; Large (>480px) photo stays normal Markdown image syntax.
    (should (string-match-p
             "!\\[架构全景图\\](https://portal\\.example/hero-photo\\.png)"
             md))
    ;; End-to-end: compiling a local HTML page with a 52x52 bounded icon backed
    ;; by a larger local PNG renders compactly in etaf-md instead of full width.
    (let* ((local-png (etaf-web-tests--fixture "sample.png"))
           (page-html (format (concat "<!DOCTYPE html><html><body><article>"
                                      "<p><img src=\"%s\" alt=\"\" width=\"52\" height=\"52\"></p>"
                                      "<p>Readable body paragraph.</p>"
                                      "</article></body></html>")
                              local-png))
           (compiled (etaf-web-to-markdown page-html))
           (session (etaf-md-create :text compiled :theme 'dark))
           (buf (etaf-md-open session)))
      (unwind-protect
          (let* ((text (with-current-buffer buf
                         (buffer-substring-no-properties (point-min) (point-max))))
                 (lines (split-string text "\n"))
                 (img-line (cl-find-if (lambda (l) (string-match-p "│▀+│" l)) lines)))
            (should img-line)
            (should (string-match "│\\(▀+\\)│" img-line))
            (should (<= (length (match-string 1 img-line)) 12))
            (should (string-match-p "Readable body paragraph\\." text)))
        (when (buffer-live-p buf)
          (with-current-buffer buf (etaf-md-close)))))))

(ert-deftest etaf-web-tests-extracts-content-column-from-wrapper-with-leading-sidebar ()
  "Bottom-up scoring + wrapper tightening isolate prose column from header/sidebar chrome."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "wrapper-sidebar-layout.html")))
         (md (etaf-web-to-markdown html :base-url "https://portal.example/")))
    ;; Stories appear cleanly with <br><br> normalized into paragraph breaks.
    (should (string-match-p "## \\[文本界面引擎发布新版增量排版器\\](https://portal\\.example/story/101)" md))
    (should (string-match-p "## \\[跨平台静态分析工具链新增离线测试套件\\](https://portal\\.example/story/102)" md))
    (should (string-match-p "维持稳定的交互响应。\n\n开发团队表示" md))
    ;; Masthead and DOM-first sidebar (poll form, hot links, follow box) are excluded.
    (should-not (string-match-p "登录\\|注册\\|每日投票\\|热门链接\\|关注我们" md))))

(ert-deftest etaf-web-tests-unwraps-layout-tables-and-keeps-data-tables ()
  "Layout tables unwrap to blocks, interactive forms and orphan headings drop, data tables stay."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-vs-data-tables.html")))
         (md (etaf-web-to-markdown html :base-url "https://essay.example/")))
    ;; Nested layout table unwrapped; inline <span class="Subscription">$</span> preserved.
    (should (string-match-p "^## \\[\\$\\] Why Classic Layout Tables Persist$" md))
    (should (string-match-p "margins and reading width\\.\n\nConverting such a layout table" md))
    (should (string-match-p "^A single-column headerless note block should also unwrap cleanly" md))
    ;; Search form and its orphaned heading are pruned.
    (should-not (string-match-p "### Search\\|Search site" md))
    ;; Real data table with <th> remains a GFM pipe table.
    (should (string-match-p "| Metric | Before | After |" md))
    (should (string-match-p "| Rows | 1 | 147 |" md))
    (should (string-match-p "| Readability | Broken | Clean |" md))))


(defun etaf-web-tests--fake-browser (dom)
  "Return an executable that prints DOM when asked for a rendered page."
  (let ((script (make-temp-file "etaf-web-fake-browser-" nil ".sh")))
    (with-temp-file script
      (insert "#!/bin/sh\ncat <<'ETAF_DOM'\n" dom "\nETAF_DOM\n"))
    (set-file-modes script #o755)
    script))

(defun etaf-web-tests--short-shell ()
  "Return the HTML a script-driven site serves before its script runs."
  "<html><head><title>App</title><script src=\"/app.js\"></script></head><body><nav>Home About</nav></body></html>")

(defun etaf-web-tests--rendered-page ()
  "Return the DOM of the page the fake browser renders, longer than a shell."
  (concat "<html><head><title>App</title></head><body><article>"
          "<h1>Rendered page</h1><p>"
          (mapconcat (lambda (_i) "正文内容足够长以便被当成真正的段落读下去。") (number-sequence 1 30) "")
          "</p></article></body></html>"))

(defmacro etaf-web-tests--with-cache (root &rest body)
  "Run BODY with `etaf-web-cache-directory' bound under ROOT."
  (declare (indent 1))
  `(let ((etaf-web-cache-directory (file-name-as-directory ,root)))
     ,@body))

(defun etaf-web-tests--http-buffer (body)
  "Wrap utf-8 BODY in an HTTP 200 response buffer."
  (etaf-web-tests--make-http-buffer
   "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8"
   (encode-coding-string body 'utf-8)))

(ert-deftest etaf-web-tests-script-page-renders-through-browser ()
  "A page whose HTML carries no prose is compiled from the rendered DOM."
  (let* ((cache (make-temp-file "etaf-web-render-" t))
         (page "https://example.test/app/")
         (browser (etaf-web-tests--fake-browser (etaf-web-tests--rendered-page)))
         (old etaf-web-render-command)
         (buffer nil))
    (unwind-protect
        (progn
          (setq etaf-web-render-command browser)
          (etaf-web-tests--with-cache cache
            (cl-letf (((symbol-function 'url-retrieve-synchronously)
                       (lambda (_url &rest _)
                         (etaf-web-tests--http-buffer (etaf-web-tests--short-shell)))))
              (setq buffer (etaf-web-open page))
              (with-current-buffer buffer
                (should (string-match-p
                         "Rendered page"
                         (buffer-substring-no-properties (point-min) (point-max))))))))
      (when (and buffer (buffer-live-p buffer)) (kill-buffer buffer))
      (setq etaf-web-render-command old)
      (ignore-errors (delete-file browser))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-page-without-prose-shows-notice ()
  "A script-only page explains itself instead of opening an empty buffer."
  (let* ((cache (make-temp-file "etaf-web-notice-" t))
         (page "https://example.test/shell/")
         (old etaf-web-render-command)
         (buffer nil))
    (unwind-protect
        (progn
          (setq etaf-web-render-command 'off)
          (etaf-web-tests--with-cache cache
            (cl-letf (((symbol-function 'url-retrieve-synchronously)
                       (lambda (_url &rest _)
                         (etaf-web-tests--http-buffer (etaf-web-tests--short-shell)))))
              (setq buffer (etaf-web-open page))
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "需要脚本渲染" text))
                  (should (string-match-p "在浏览器打开" text)))))
            (let* ((page-dir (car (etaf-web-tests--cached-page-dirs cache)))
                   (index (etaf-web-tests--read-file (expand-file-name "index.md" page-dir))))
              (should (string-match-p "需要脚本渲染" index))
              (should (string-match-p (regexp-quote page) index)))))
      (when (and buffer (buffer-live-p buffer)) (kill-buffer buffer))
      (setq etaf-web-render-command old)
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-short-page-is-not-a-shell ()
  "A genuinely short page keeps its paragraph instead of a notice."
  (let* ((cache (make-temp-file "etaf-web-short-" t))
         (page "https://example.test/note/")
         (paragraph (concat "这一页只有一段话，但它确实是一段正常的正文，"
                            "所以它应该原样读出来，不需要任何额外提示。"))
         (buffer nil))
    (unwind-protect
        (etaf-web-tests--with-cache cache
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (_url &rest _)
                       (etaf-web-tests--http-buffer
                        (format "<html><head><title>Note</title></head><body><article><p>%s</p></article></body></html>"
                                paragraph)))))
            (setq buffer (etaf-web-open page))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "只有一段话" text))
                (should-not (string-match-p "需要脚本渲染" text))))))
      (when (and buffer (buffer-live-p buffer)) (kill-buffer buffer))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-cache-backfills-missing-images ()
  "Reopening a cached page downloads images its first pass could not save."
  (let* ((cache (make-temp-file "etaf-web-backfill-" t))
         (page "https://example.test/photo/")
         (image "https://example.test/photo/hero.png")
         (png (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally
                 (etaf-web-tests--fixture "sample.png"))
                (buffer-string)))
         (html (concat "<html><head><title>Photo</title></head><body><article>"
                       "<h1>Photo</h1><p>一段足够长的正文，用来保证这个页面不会被当成空壳页面处理。</p>"
                       "<img src=\"hero.png\" alt=\"Hero\"></article></body></html>"))
         (old-download etaf-web-download-images)
         (buffer nil)
         (page-dir nil))
    (unwind-protect
        (etaf-web-tests--with-cache cache
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (url &rest _)
                       (cond
                        ((equal url page)
                         (etaf-web-tests--http-buffer html))
                        ((equal url image)
                         (etaf-web-tests--make-http-buffer
                          "HTTP/1.1 200 OK\r\nContent-Type: image/png" png))
                        (t (etaf-web-tests--make-http-buffer
                            "HTTP/1.1 404 Not Found\r\nContent-Type: text/html"
                            "<html></html>"))))))
            ;; First pass keeps the remote URL, as a failed download would.
            (setq etaf-web-download-images nil)
            (setq buffer (etaf-web-open page))
            (when (buffer-live-p buffer) (kill-buffer buffer))
            (setq page-dir (car (etaf-web-tests--cached-page-dirs cache)))
            (let ((index (etaf-web-tests--read-file
                          (expand-file-name "index.md" page-dir))))
              (should (string-match-p (regexp-quote image) index))
              (should-not (file-directory-p (expand-file-name "assets" page-dir))))
            ;; The second pass fills the hole without the reader clearing the cache.
            (setq etaf-web-download-images t)
            (setq buffer (etaf-web-open page))
            (let ((index (etaf-web-tests--read-file
                          (expand-file-name "index.md" page-dir))))
              (should-not (string-match-p (regexp-quote image) index))
              (should (string-match-p (regexp-quote "](assets/") index))
              (should (> (length (directory-files
                                  (expand-file-name "assets" page-dir)))
                         2)))))
      (setq etaf-web-download-images old-download)
      (when (and buffer (buffer-live-p buffer)) (kill-buffer buffer))
      (delete-directory cache t))))

(provide 'etaf-web-tests)
;;; etaf-web-tests.el ends here
