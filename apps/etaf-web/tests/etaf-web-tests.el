;;; etaf-web-tests.el --- Public API acceptance tests for etaf-web -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public API behavior scenarios for `etaf-web'.  Every test exercises only
;; declared public interfaces (`etaf-web-to-markdown', `etaf-web-open',
;; `etaf-web-back', `etaf-web-forward', `etaf-web-reload', `etaf-web-stop',
;; `etaf-web-focus-address', `etaf-web-open-external', `etaf-web-close',
;; `etaf-web-state', `etaf-web-cache-directory', `etaf-web-download-images',
;; `etaf-web-fetch-timeout', `etaf-web-render-command', `etaf-web-error')
;; and observable on-disk cache artifacts (`index.md', `source.html',
;; `meta.json', `assets/').

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)
(require 'etaf)
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

(defun etaf-web-tests--cached-page-dirs (cache-root)
  "Return list of page directories created under CACHE-ROOT/pages/."
  (let ((pages (expand-file-name "pages" cache-root)))
    (when (file-directory-p pages)
      (cl-remove-if-not
       #'file-directory-p
       (directory-files pages t "\\`[^.]")))))

(defun etaf-web-tests--wait-until (predicate &optional timeout)
  "Pump Emacs events until PREDICATE returns non-nil or TIMEOUT seconds pass."
  (let ((deadline (+ (float-time) (or timeout 8.0)))
        (val nil))
    (while (and (not (setq val (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sleep-for 0.01))
    val))

(defun etaf-web-tests--wait-phase (buf phases &optional timeout)
  "Wait until `etaf-web-state' of BUF reaches one of PHASES (symbol or list)."
  (let ((targets (if (listp phases) phases (list phases))))
    (unless (etaf-web-tests--wait-until
             (lambda ()
               (and (buffer-live-p buf)
                    (memq (plist-get (etaf-web-state buf) :phase) targets)))
             timeout)
      (ert-fail (format "Timed out waiting for phase %S; current state: %S"
                        targets (and (buffer-live-p buf) (etaf-web-state buf)))))))

(defun etaf-web-tests--http-start (handler)
  "Start a loopback HTTP/1.1 test server on 127.0.0.1:0 calling HANDLER.
HANDLER receives `(METHOD PATH)' and returns a plist with optional keys
`:status', `:headers', `:body', `:delay', `:close'.  Returns `(SERVER . URL)'."
  (let ((timers nil)
        (clients nil)
        (server nil))
    (setq server
          (make-network-process
           :name "etaf-web-test-httpd"
           :server t
           :host "127.0.0.1"
           :service 0
           :family 'ipv4
           :noquery t
           :coding 'no-conversion
           :sentinel #'ignore
           :filter
           (lambda (proc chunk)
             (push proc clients)
             (let ((buf (concat (or (process-get proc :req) "") chunk)))
               (process-put proc :req buf)
               (when (and (not (process-get proc :handled))
                          (string-match "\\`\\([A-Z]+\\) \\([^ \r\n]+\\) HTTP/" buf)
                          (string-match-p "\r\n\r\n" buf))
                 (process-put proc :handled t)
                 (let* ((method (match-string 1 buf))
                        (path (match-string 2 buf))
                        (resp (funcall handler method path))
                        (delay (plist-get resp :delay)))
                   (cl-labels
                       ((send-now ()
                          (when (process-live-p proc)
                            (if (plist-get resp :close)
                                (delete-process proc)
                              (let* ((status (or (plist-get resp :status) "200 OK"))
                                     (headers (or (plist-get resp :headers)
                                                  "Content-Type: text/html; charset=utf-8"))
                                     (raw-body (or (plist-get resp :body) ""))
                                     (body (if (multibyte-string-p raw-body)
                                               (encode-coding-string raw-body 'utf-8)
                                             raw-body))
                                     (wire (concat
                                            (format "HTTP/1.1 %s\r\n%s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                                                    status headers (length body))
                                            body)))
                                (ignore-errors (process-send-string proc wire))
                                (ignore-errors (process-send-eof proc)))))))
                     (if (and (numberp delay) (> delay 0))
                         (push (run-at-time delay nil #'send-now) timers)
                       (send-now)))))))))
    (process-put server :cleanup
                 (lambda ()
                   (dolist (tm timers) (when (timerp tm) (cancel-timer tm)))
                   (dolist (c clients) (when (process-live-p c) (delete-process c)))
                   (when (process-live-p server) (delete-process server))))
    (cons server (format "http://127.0.0.1:%d" (process-contact server :service)))))

(defun etaf-web-tests--http-stop (server)
  "Stop loopback HTTP test SERVER and cancel all pending timers/clients."
  (when-let* ((fn (and server (process-get server :cleanup))))
    (funcall fn)))

(defmacro etaf-web-tests--with-http (base-var handler &rest body)
  "Run BODY with loopback HTTP server dispatching to HANDLER bound to BASE-VAR."
  (declare (indent 2))
  (let ((srv (make-symbol "srv")))
    `(let* ((url-proxy-services nil)
            (,srv (etaf-web-tests--http-start ,handler))
            (,base-var (cdr ,srv)))
       (unwind-protect
           (progn ,@body)
         (etaf-web-tests--http-stop (car ,srv))))))

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

(defun etaf-web-tests--reveal (buffer text)
  "Scroll BUFFER's page viewport until TEXT shows; return its position or nil.
A long document shows one screen at a time inside its scrolling viewport, so a
test scrolls the same way a reader does."
  (with-current-buffer buffer
    (switch-to-buffer buffer)
    (let* ((rt (etaf-runtime-for-buffer buffer))
           (found (progn (etaf-scroll-to rt 'web-scroll 0)
                         (etaf-runtime-flush rt)
                         (save-excursion (goto-char (point-min))
                                         (search-forward text nil t))))
           (rounds 0))
      (while (and (not found) (< rounds 60))
        (etaf-scroll-by rt 'web-scroll 6)
        (etaf-runtime-flush rt)
        (setq found (save-excursion (goto-char (point-min))
                                    (search-forward text nil t)))
        (setq rounds (1+ rounds)))
      found)))

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
            (should (string-match-p "Building Text Renderers in Emacs" painted)))
          (should (etaf-web-tests--reveal buf "defun render-box"))
          (should (etaf-web-tests--reveal buf "Figure 1: Rendering pipeline stages"))
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
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-url-fetch-caches-and-skips-refetch ()
  "Async HTTP fetch decodes charset, caches files and skips second fetch."
  (let* ((cache-root (make-temp-file "etaf-web-http-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images t)
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
                            "<p>正文内容与图片，长度足够以保证页面作为完整正文渲染而不会触发空壳判定：</p>"
                            "<figure><img src=\"hero.png\" alt=\"示意图\">"
                            "<figcaption>图 1 架构</figcaption></figure>"
                            "<img src=\"missing.png\" alt=\"缺失图\">"
                            "</article></body></html>")
                    'gb18030))
         (fetch-log nil)
         (buf1 nil)
         (buf2 nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_method path)
              (push path fetch-log)
              (pcase path
                ("/guide/start.html"
                 (list :status "200 OK"
                       :headers "Content-Type: text/html\r\nETag: \"v1\""
                       :body gbk-html))
                ("/guide/hero.png"
                 (list :status "200 OK"
                       :headers "Content-Type: image/png"
                       :body png-bytes))
                (_
                 (list :status "404 Not Found"
                       :headers "Content-Type: text/plain"
                       :body "not found"))))
          (let ((page-url (concat base "/guide/start.html"))
                (missing-url (concat base "/guide/missing.png")))
            ;; First open: fetches HTML + two images asynchronously (one succeeds, one 404s).
            (setq buf1 (etaf-web-open page-url))
            (should (buffer-live-p buf1))
            (etaf-web-tests--wait-phase buf1 'ready)
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let* ((dirs (etaf-web-tests--cached-page-dirs cache-root))
                              (dir (car dirs))
                              (idx (and dir (expand-file-name "index.md" dir))))
                         (and idx (file-readable-p idx)
                              (>= (length fetch-log) 3)
                              (string-match-p "](assets/" (etaf-web-tests--read-file idx)))))))
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
                         (format "!\\[缺失图\\](%s)" (regexp-quote missing-url))
                         index-md)))
              (with-current-buffer buf1 (etaf-web-close))
              (setq buf1 nil)
              ;; Second open reuses index.md: the page and saved image are not refetched.
              (setq buf2 (etaf-web-open page-url))
              (should (buffer-live-p buf2))
              (etaf-web-tests--wait-phase buf2 'ready)
              (should (plist-get (etaf-web-state buf2) :cached))
              (should (= (cl-count "/guide/start.html" fetch-log :test #'equal) 1))
              (should (= (cl-count "/guide/hero.png" fetch-log :test #'equal) 1))
              (let ((painted2 (with-current-buffer buf2
                                (buffer-substring-no-properties (point-min) (point-max)))))
                (should (string-match-p "中文指南" painted2))))))
      (when (buffer-live-p buf1)
        (with-current-buffer buf1 (etaf-web-close)))
      (when (buffer-live-p buf2)
        (with-current-buffer buf2 (etaf-web-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-disable-image-downloads-and-error-conditions ()
  "Disabling image downloads keeps remote URLs; bad inputs signal errors."
  (let* ((cache-root (make-temp-file "etaf-web-noimg-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images nil)
         (fetched nil)
         (buf nil))
    (unwind-protect
        (progn
          (should-error (etaf-web-to-markdown 123) :type 'etaf-web-error)
          (should-error (etaf-web-open "/nonexistent/etaf-web-missing.html")
                        :type 'etaf-web-error)
          (etaf-web-tests--with-http base
              (lambda (_method path)
                (push path fetched)
                (list :status "200 OK"
                      :body "<article><h1>No DL</h1><p>Body paragraph without image downloading enabled.</p><img src=\"pic.png\" alt=\"Pic\"></article>"))
            (let ((page-url (concat base "/no-images.html")))
              (setq buf (etaf-web-open page-url))
              (etaf-web-tests--wait-phase buf 'ready)
              (should (equal fetched '("/no-images.html")))
              (let* ((page-dir (car (etaf-web-tests--cached-page-dirs cache-root)))
                     (index-md (etaf-web-tests--read-file
                                (expand-file-name "index.md" page-dir))))
                (should (string-match-p
                         (format "!\\[Pic\\](%s/pic\\.png)" (regexp-quote base))
                         index-md))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache-root t))))

(ert-deftest etaf-web-tests-http-link-navigation-and-anchor-jump ()
  "Activating an HTTP link navigates inside `etaf-web'; `#anchor' jumps locally."
  (let* ((cache-root (make-temp-file "etaf-web-nav-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images nil)
         (browsed nil)
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_method path)
              (pcase path
                ("/a.html"
                 (list :status "200 OK"
                       :body (concat "<article><h1>Page Alpha</h1>"
                                     "<p><a href=\"#sec-end\">Jump Down</a> and "
                                     "<a href=\"b.html\">Next Page</a>.</p>"
                                     "<h2 id=\"sec-end\">Section End</h2>"
                                     "<p>Enough body text on Alpha to render directly.</p></article>")))
                ("/b.html"
                 (list :status "200 OK"
                       :body "<article><h1>Page Beta</h1><p>Arrived on Beta with clear prose.</p></article>"))
                (_ (list :status "404 Not Found" :body "missing"))))
          (cl-letf (((symbol-function 'browse-url)
                     (lambda (u &rest _) (push u browsed))))
            (let ((url-a (concat base "/a.html"))
                  (url-b (concat base "/b.html")))
              (setq buf (etaf-web-open url-a))
              (etaf-web-tests--wait-phase buf 'ready)
              (with-current-buffer buf
                ;; `#anchor' link resolves HTML heading id and jumps in-document.
                (goto-char (point-min))
                (should (search-forward "Jump Down" nil t))
                (goto-char (match-beginning 0))
                (call-interactively (key-binding (kbd "RET")))
                (should (looking-at-p "Section End"))
                ;; HTTP link navigates inside the browser shell instead of browse-url.
                (goto-char (point-min))
                (should (search-forward "Next Page" nil t))
                (goto-char (match-beginning 0))
                (call-interactively (key-binding (kbd "RET"))))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) url-b)
                                (eq (plist-get st :phase) 'ready))))))
              (let ((painted (with-current-buffer buf
                               (buffer-substring-no-properties (point-min) (point-max)))))
                (should (string-match-p "Page Beta" painted))
                (should (string-match-p "Arrived on Beta" painted))
                (should-not browsed)))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-web-close)))
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
  "`etaf-web-fetch-timeout' bounds fetches; HTTP, timeout and connection errors differ."
  (let* ((cache-root (make-temp-file "etaf-web-timeout-cache-" t))
         (etaf-web-cache-directory cache-root)
         (etaf-web-download-images nil)
         (etaf-web-fetch-timeout 0.4)
         (sample-html (etaf-web-tests--read-file
                       (etaf-web-tests--fixture "mdn-fetch-snippet.html")))
         (closed-url nil)
         (buf nil))
    (unwind-protect
        (progn
          (etaf-web-tests--with-http base
              (lambda (_method path)
                (pcase path
                  ("/api/fetch" (list :status "200 OK" :body sample-html))
                  ("/forbidden" (list :status "403 Forbidden" :body "<h1>Forbidden</h1>"))
                  ("/slow" (list :status "200 OK" :delay 3.0 :body "<p>too late</p>"))
                  (_ (list :status "404 Not Found" :body "nope"))))
            (setq closed-url (concat base "/down"))
            ;; 1. Normal fetch succeeds within timeout.
            (setq buf (etaf-web-open (concat base "/api/fetch")))
            (etaf-web-tests--wait-phase buf 'ready)
            (with-current-buffer buf (etaf-web-close))
            (setq buf nil)
            ;; 2. HTTP 403 renders error card with distinct HTTP status message.
            (setq buf (etaf-web-open (concat base "/forbidden")))
            (etaf-web-tests--wait-phase buf 'error)
            (let* ((st (etaf-web-state buf))
                   (err-msg (plist-get (plist-get st :error) :message))
                   (painted (with-current-buffer buf
                              (buffer-substring-no-properties (point-min) (point-max)))))
              (should (string-match-p "403" err-msg))
              (should (string-match-p "无法加载页面" painted))
              (should (string-match-p "重试" painted))
              (with-current-buffer buf (etaf-web-close))
              (setq buf nil)
              ;; 3. Timeout reports distinct timeout error naming `etaf-web-fetch-timeout'.
              (setq buf (etaf-web-open (concat base "/slow")))
              (etaf-web-tests--wait-phase buf 'error 5.0)
              (let ((timeout-msg (plist-get (plist-get (etaf-web-state buf) :error) :message)))
                (should (string-match-p "Timed out" timeout-msg))
                (should (string-match-p "0\\.4" timeout-msg))
                (with-current-buffer buf (etaf-web-close))
                (setq buf nil)
                ;; 4. After server stops, closed port yields distinct connection failure.
                (let ((conn-msg nil))
                  (etaf-web-tests--with-http tmp-base (lambda (_m _p) (list :close t))
                    (setq closed-url (concat tmp-base "/down")))
                  (setq buf (etaf-web-open closed-url))
                  (etaf-web-tests--wait-phase buf 'error 5.0)
                  (setq conn-msg (plist-get (plist-get (etaf-web-state buf) :error) :message))
                  (should (string-match-p "Connection failed" conn-msg))
                  (should-not (equal timeout-msg conn-msg))
                  (should-not (equal err-msg conn-msg)))))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (etaf-web-close)))
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
                 (img-line (cl-find-if (lambda (l) (string-match-p "▀+" l)) lines)))
            (should img-line)
            (should (string-match "\\(▀+\\)" img-line))
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
         (browser (etaf-web-tests--fake-browser (etaf-web-tests--rendered-page)))
         (old etaf-web-render-command)
         (buffer nil))
    (unwind-protect
        (progn
          (setq etaf-web-render-command browser)
          (etaf-web-tests--with-cache cache
            (etaf-web-tests--with-http base
                (lambda (_m _p) (list :status "200 OK" :body (etaf-web-tests--short-shell)))
              (setq buffer (etaf-web-open (concat base "/app/")))
              (etaf-web-tests--wait-phase buffer 'ready)
              (with-current-buffer buffer
                (should (string-match-p
                         "Rendered page"
                         (buffer-substring-no-properties (point-min) (point-max))))))))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer (etaf-web-close)))
      (setq etaf-web-render-command old)
      (ignore-errors (delete-file browser))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-page-without-prose-shows-notice ()
  "A script-only page explains itself instead of opening an empty buffer."
  (let* ((cache (make-temp-file "etaf-web-notice-" t))
         (old etaf-web-render-command)
         (buffer nil))
    (unwind-protect
        (progn
          (setq etaf-web-render-command 'off)
          (etaf-web-tests--with-cache cache
            (etaf-web-tests--with-http base
                (lambda (_m _p) (list :status "200 OK" :body (etaf-web-tests--short-shell)))
              (let ((page (concat base "/shell/")))
                (setq buffer (etaf-web-open page))
                (etaf-web-tests--wait-phase buffer 'ready)
                (with-current-buffer buffer
                  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "需要脚本渲染" text))
                    (should (string-match-p "在浏览器打开" text))))
                (let* ((page-dir (car (etaf-web-tests--cached-page-dirs cache)))
                       (index (etaf-web-tests--read-file
                               (expand-file-name "index.md" page-dir))))
                  (should (string-match-p "需要脚本渲染" index))
                  (should (string-match-p (regexp-quote page) index)))))))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer (etaf-web-close)))
      (setq etaf-web-render-command old)
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-short-page-is-not-a-shell ()
  "A genuinely short page keeps its paragraph instead of a notice."
  (let* ((cache (make-temp-file "etaf-web-short-" t))
         (paragraph (concat "这一页只有一段话，但它确实是一段正常的正文，"
                            "所以它应该原样读出来，不需要任何额外提示。"))
         (buffer nil))
    (unwind-protect
        (etaf-web-tests--with-cache cache
          (etaf-web-tests--with-http base
              (lambda (_m _p)
                (list :status "200 OK"
                      :body (format "<html><head><title>Note</title></head><body><article><p>%s</p></article></body></html>"
                                    paragraph)))
            (setq buffer (etaf-web-open (concat base "/note/")))
            (etaf-web-tests--wait-phase buffer 'ready)
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "只有一段话" text))
                (should-not (string-match-p "需要脚本渲染" text))))))
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-cache-backfills-missing-images ()
  "Reopening a cached page downloads images its first pass could not save."
  (let* ((cache (make-temp-file "etaf-web-backfill-" t))
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
          (etaf-web-tests--with-http base
              (lambda (_m path)
                (pcase path
                  ("/photo/" (list :status "200 OK" :body html))
                  ("/photo/hero.png" (list :status "200 OK"
                                           :headers "Content-Type: image/png"
                                           :body png))
                  (_ (list :status "404 Not Found" :body "<html></html>"))))
            (let ((page (concat base "/photo/"))
                  (image (concat base "/photo/hero.png")))
              ;; First pass keeps remote URL, as a failed download would.
              (setq etaf-web-download-images nil)
              (setq buffer (etaf-web-open page))
              (etaf-web-tests--wait-phase buffer 'ready)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer (etaf-web-close)))
              (setq buffer nil)
              (setq page-dir (car (etaf-web-tests--cached-page-dirs cache)))
              (let ((index (etaf-web-tests--read-file
                            (expand-file-name "index.md" page-dir))))
                (should (string-match-p (regexp-quote image) index))
                (should-not (file-directory-p (expand-file-name "assets" page-dir))))
              ;; Second pass fills the hole asynchronously without clearing cache.
              (setq etaf-web-download-images t)
              (setq buffer (etaf-web-open page))
              (etaf-web-tests--wait-phase buffer 'ready)
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((idx (etaf-web-tests--read-file
                                     (expand-file-name "index.md" page-dir))))
                           (string-match-p (regexp-quote "](assets/") idx)))))
              (let ((index (etaf-web-tests--read-file
                            (expand-file-name "index.md" page-dir))))
                (should-not (string-match-p (regexp-quote image) index))
                (should (string-match-p (regexp-quote "](assets/") index))
                (should (> (length (directory-files
                                    (expand-file-name "assets" page-dir)))
                           2))))))
      (setq etaf-web-download-images old-download)
      (when (and buffer (buffer-live-p buffer))
        (with-current-buffer buffer (etaf-web-close)))
      (delete-directory cache t))))

;;; ---------------------------------------------------------------------------
;;; Universal layout/extraction rules & interactive browser shell tests
;;; ---------------------------------------------------------------------------

(ert-deftest etaf-web-tests-prunes-hidden-search-and-punct-blocks ()
  "Hidden nodes (except tabpanels), ARIA overlays, short search bars and punct blocks drop."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "pruning-hidden-search-punct.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    (dolist (noise '("不应该出现的隐藏提示文本" "同样不可见的悬浮文案"
                     "悬浮提示" "菜单项一" "登录弹窗标题" "警告弹窗" "搜索文章"))
      (should-not (string-match-p (regexp-quote noise) md)))
    ;; Lone punctuation/pipe leaf lines are removed.
    (should-not (string-match-p "^[|·/]$" md))
    ;; Normal prose and inactive `role="tabpanel"` stay intact inside :::tabs.
    (should (string-match-p "这是正常保留的主体正文段落" md))
    (should (string-match-p "^:::tabs$" md))
    (should (string-match-p "make check" md))
    (should (string-match-p "make test" md))))

(ert-deftest etaf-web-tests-timeline-gate-rejects-counter-bars ()
  "Counter/action bars with timeline class are rejected; real timelines remain :::timeline."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "timeline-gate-and-metadata.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; Counter bar collapses to single metadata line instead of :::timeline.
    (should (string-match-p "^3月前 · 1\\.0k · 8$" md))
    ;; Genuine timeline with <time> and substantive text stays :::timeline.
    (should (string-match-p "^:::timeline$" md))
    (should (string-match-p ":::event {title=\"基础引擎\" time=\"2026-01\"}" md))
    (should (string-match-p ":::event {title=\"浏览器外壳\" time=\"2026-04\"}" md))
    (should-not (string-match-p ":::event.*3月前" md))))

(ert-deftest etaf-web-tests-clusters-short-metadata-and-preserves-cards ()
  "Consecutive short metadata siblings merge into one line while card grids stay intact."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "timeline-gate-and-metadata.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; Four consecutive short stat blocks merge into a single ` · '-joined line.
    (should (string-match-p "^关注 18 · 粉丝 204 · 获赞 1\\.2k · 文章 36$" md))
    ;; Feature cards keep their card/columns structure untouched.
    (should (string-match-p "^:::card {title=\"异步管线\"}\n抓取与无头渲染完全非阻塞运行。" md))
    (should (string-match-p "^:::card {title=\"结构保留\"}\n卡片内部段落与标题维持原有语义。" md))))

(ert-deftest etaf-web-tests-formats-repeated-entry-stream ()
  "Homogeneous entry streams compile into linked headings, prose summaries, meta line and hr."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "repeated-entry-stream.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    (should (string-match-p
             "^### \\[深入理解增量排版引擎的脏区计算\\](https://example\\.com/post/101)$" md))
    (should (string-match-p
             "^### \\[终端文本应用里的异步状态机设计\\](https://example\\.com/post/102)$" md))
    (should (string-match-p
             "^### \\[面向通用网页的噪音剪枝与版式恢复\\](https://example\\.com/post/103)$" md))
    ;; Summary unwraps same-href link into plain prose rather than nested link.
    (should (string-match-p "^本文剖析保留式渲染树如何只重排变更的节点" md))
    (should-not (string-match-p "\\[本文剖析" md))
    ;; Single-line metadata and horizontal rule separators between entries.
    (should (string-match-p "^3月前 · 1\\.2k · 18$" md))
    (should (string-match-p "^4月前 · 980 · 12$" md))
    (should (string-match-p "^---$" md))))

(ert-deftest etaf-web-tests-handles-inline-badges-pua-and-emoji ()
  "Empty-alt inline imgs drop, badge runs degrade to alt text, PUA strips, real emoji stays."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "inline-badges-pua-emoji.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/")))
    ;; Empty-alt decorative inline img dropped completely.
    (should-not (string-match-p "icon-deco\\.png" md))
    ;; Run of inline badge images degrades to `alt` text joined with ` · '.
    (should (string-match-p "创作等级LV\\.4 · 杰出作者 · 博览群文" md))
    (should-not (string-match-p "b1\\.png\\|b2\\.png\\|b3\\.png" md))
    ;; PUA glyphs and variation selectors stripped; standard emoji preserved.
    (should-not (string-match-p "[\ue000-\uf8ff\ufe0e\ufe0f]" md))
    (should (string-match-p "🚀" md))
    (should (string-match-p "📝" md))))

(ert-deftest etaf-web-tests-browser-history-scroll-and-reload ()
  "Back/Forward restore scroll positions and `r' reloads bypassing cache via real keys."
  (let* ((cache (make-temp-file "etaf-web-hist-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (ver 1)
         (page1-body (concat "<article><h1>First Long Page</h1>"
                             (mapconcat (lambda (i)
                                          (format "<p>Paragraph %d with enough text to scroll through cleanly.</p>" i))
                                        (number-sequence 1 35) "")
                             "<p><a href=\"/p2\">Go Second</a></p></article>"))
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/p1" (list :status "200 OK" :body page1-body))
                ("/p2" (list :status "200 OK"
                             :body (format "<article><h1>Second Page v%d</h1><p>Version %d readable content body.</p></article>"
                                           ver ver)))
                (_ (list :status "404 Not Found" :body "404"))))
          (let ((u1 (concat base "/p1"))
                (u2 (concat base "/p2"))
                (saved-pt nil))
            (setq buf (etaf-web-open u1))
            (etaf-web-tests--wait-phase buf 'ready)
            (with-current-buffer buf
              ;; Scroll down to bottom link and activate it.
              (goto-char (point-min))
              (should (etaf-web-tests--reveal buf "Go Second"))
              (goto-char (match-beginning 0))
              (setq saved-pt (point))
              (should (> saved-pt 200))
              (call-interactively (key-binding (kbd "RET"))))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf)))
                         (and (equal (plist-get st :url) u2)
                              (eq (plist-get st :phase) 'ready))))))
            (let ((st2 (etaf-web-state buf)))
              (should (plist-get st2 :can-back))
              (should-not (plist-get st2 :can-forward))
              (should (= (plist-get st2 :history-length) 2)))
            ;; Drive real `M-<left>' key -> goes back to u1 and restores point!
            (with-current-buffer buf
              (execute-kbd-macro (kbd "M-<left>")))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf)))
                         (and (equal (plist-get st :url) u1)
                              (eq (plist-get st :phase) 'ready))))))
            (let ((st-back (etaf-web-state buf)))
              (should-not (plist-get st-back :can-back))
              (should (plist-get st-back :can-forward))
              (should (= (with-current-buffer buf (point)) saved-pt)))
            ;; Drive real `M-<right>' key -> goes forward to u2!
            (with-current-buffer buf
              (execute-kbd-macro (kbd "M-<right>")))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf)))
                         (and (equal (plist-get st :url) u2)
                              (eq (plist-get st :phase) 'ready))))))
            ;; Bump server version and drive real `r' key -> bypasses cache!
            (setq ver 2)
            (with-current-buffer buf
              (execute-kbd-macro "r"))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (and (eq (plist-get (etaf-web-state buf) :phase) 'ready)
                            (string-match-p
                             "Version 2"
                             (with-current-buffer buf
                               (buffer-substring-no-properties (point-min) (point-max))))))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-address-bar-and-independent-buffers ()
  "Opening two pages yields independent `*Web: ...*' buffers; `g' edits address bar."
  (let* ((cache (make-temp-file "etaf-web-addr-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf1 nil)
         (buf2 nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/one" (list :status "200 OK"
                              :body "<article><h1>Page One</h1><p>First independent page content.</p></article>"))
                ("/two" (list :status "200 OK"
                              :body "<article><h1>Page Two</h1><p>Second independent page content.</p></article>"))
                ("/three" (list :status "200 OK"
                                :body "<article><h1>Page Three</h1><p>Reached through address bar.</p></article>"))
                (_ (list :status "404 Not Found" :body "404"))))
          (let ((u1 (concat base "/one"))
                (u2 (concat base "/two"))
                (u3 (concat base "/three")))
            (setq buf1 (etaf-web-open u1))
            (setq buf2 (etaf-web-open u2))
            (etaf-web-tests--wait-phase buf1 'ready)
            (etaf-web-tests--wait-phase buf2 'ready)
            ;; Two distinct live browser buffers named `*Web: ...*'.
            (should-not (eq buf1 buf2))
            (should (string-prefix-p "*Web: " (buffer-name buf1)))
            (should (string-prefix-p "*Web: " (buffer-name buf2)))
            (should (string-match-p "Page One"
                                    (with-current-buffer buf1
                                      (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Page Two"
                                    (with-current-buffer buf2
                                      (buffer-substring-no-properties (point-min) (point-max)))))
            ;; Switch to buf1 and press real `g' to edit address bar, enter u3, press RET.
            (switch-to-buffer buf1)
            (execute-kbd-macro "g")
            (should (plist-get (etaf-web-state buf1) :address-editing))
            (execute-kbd-macro (vconcat (kbd "C-a") (kbd "C-k") u3 (kbd "RET")))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf1)))
                         (and (equal (plist-get st :url) u3)
                              (eq (plist-get st :phase) 'ready))))))
            ;; buf1 updated to Page Three while buf2 remains completely untouched.
            (should (string-match-p "Reached through address bar"
                                    (with-current-buffer buf1
                                      (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Page Two"
                                    (with-current-buffer buf2
                                      (buffer-substring-no-properties (point-min) (point-max)))))))
      (when (and buf1 (buffer-live-p buf1))
        (with-current-buffer buf1 (etaf-web-close)))
      (when (and buf2 (buffer-live-p buf2))
        (with-current-buffer buf2 (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-cancel-inflight-load-leaves-no-orphans ()
  "Pressing `x' cancels an in-flight slow load immediately with zero orphan subprocesses."
  (let* ((cache (make-temp-file "etaf-web-cancel-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p) (list :status "200 OK" :delay 10.0 :body "<p>slow</p>"))
          (setq buf (etaf-web-open (concat base "/hang")))
          (should (eq (plist-get (etaf-web-state buf) :phase) 'loading))
          (accept-process-output nil 0.05)
          ;; Drive real `x' key to stop in-flight fetch.
          (with-current-buffer buf
            (execute-kbd-macro "x"))
          (etaf-web-tests--wait-phase buf 'error 2.0)
          (let ((st (etaf-web-state buf))
                (fetch-procs (cl-remove-if-not
                              (lambda (p)
                                (and (process-live-p p)
                                     (string-match-p "etaf-web-fetch\\|etaf-web-render"
                                                     (process-name p))))
                              (process-list))))
            (should (eq (plist-get (plist-get st :error) :kind) 'cancelled))
            (should (null fetch-procs))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-error-card-actions-and-narrow-viewport ()
  "Error card exposes Retry, External Browser and Back buttons; narrow mode folds toolbar."
  (let* ((cache (make-temp-file "etaf-web-errcard-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (fail-b t)
         (browsed nil)
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/ok" (list :status "200 OK"
                             :body "<article><h1>Origin Page</h1><p><a href=\"/flaky\">Open Flaky</a></p></article>"))
                ("/flaky" (if fail-b
                              (list :status "503 Service Unavailable" :body "down")
                            (list :status "200 OK"
                                  :body "<article><h1>Recovered Page</h1><p>Back online now.</p></article>")))
                (_ (list :status "404 Not Found" :body "404"))))
          (cl-letf (((symbol-function 'browse-url)
                     (lambda (u &rest _) (push u browsed))))
            (let ((u-ok (concat base "/ok"))
                  (u-flaky (concat base "/flaky")))
              (setq buf (etaf-web-open u-ok))
              (etaf-web-tests--wait-phase buf 'ready)
              ;; Navigate to flaky page -> lands on error card with all 3 buttons.
              (with-current-buffer buf
                (goto-char (point-min))
                (should (search-forward "Open Flaky" nil t))
                (goto-char (match-beginning 0))
                (call-interactively (key-binding (kbd "RET"))))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u-flaky)
                                (eq (plist-get st :phase) 'error))))))
              (let ((painted (with-current-buffer buf
                               (buffer-substring-no-properties (point-min) (point-max)))))
                (should (string-match-p "无法加载页面" painted))
                (should (string-match-p "503" painted))
                (should (string-match-p (regexp-quote u-flaky) painted))
                (should (string-match-p "重试" painted))
                (should (string-match-p "外部浏览器" painted))
                (should (string-match-p "返回上页" painted)))
              ;; Button 1: External Browser via `etaf-focus' + `RET'.
              (let ((rt (etaf-runtime-for-buffer buf)))
                (with-current-buffer buf
                  (etaf-focus rt 'web-error-browser)
                  (execute-kbd-macro (kbd "RET")))
                (should (equal browsed (list u-flaky)))
                ;; Button 2: Back via `etaf-focus' + `RET'.
                (with-current-buffer buf
                  (etaf-focus rt 'web-error-back)
                  (execute-kbd-macro (kbd "RET")))
                (should (etaf-web-tests--wait-until
                         (lambda ()
                           (let ((st (etaf-web-state buf)))
                             (and (equal (plist-get st :url) u-ok)
                                  (eq (plist-get st :phase) 'ready))))))
                ;; Go forward back to flaky error card, flip server healthy, activate Retry!
                (with-current-buffer buf (execute-kbd-macro (kbd "M-<right>")))
                (etaf-web-tests--wait-phase buf 'error)
                (setq fail-b nil)
                (with-current-buffer buf
                  (etaf-focus rt 'web-error-retry)
                  (execute-kbd-macro (kbd "RET")))
                (etaf-web-tests--wait-phase buf 'ready)
                (should (string-match-p "Recovered Page"
                                        (with-current-buffer buf
                                          (buffer-substring-no-properties (point-min) (point-max)))))
                ;; Wide 1lh header: left Chinese actions + full URL with scheme + no footer.
                (let ((wide-text (with-current-buffer buf
                                   (buffer-substring-no-properties (point-min) (point-max)))))
                  (should (string-match-p "后退.*前进.*刷新" wide-text))
                  (should (string-match-p (regexp-quote u-flaky) wide-text)))
                ;; Narrow viewport (<72ch) triggers `:narrow t', folds to `‹ › ⟳', keeps scheme.
                (let ((w-orig (selected-window))
                      (w-right (ignore-errors (split-window-horizontally 56)))
                      (buf-narrow nil))
                  (unwind-protect
                      (when (window-live-p w-right)
                        (select-window w-orig)
                        (setq buf-narrow (etaf-web-open u-ok))
                        (etaf-web-tests--wait-phase buf-narrow 'ready)
                        (let ((st-n (etaf-web-state buf-narrow))
                              (painted-n (with-current-buffer buf-narrow
                                           (buffer-substring-no-properties (point-min) (point-max)))))
                          (should (< (plist-get st-n :width) 72))
                          (should (plist-get st-n :narrow))
                          (should (string-match-p "‹.*›.*⟳" painted-n))
                          (should (string-match-p "http://" painted-n))
                          (should-not (string-match-p "后退" painted-n))))
                    (when (and buf-narrow (buffer-live-p buf-narrow))
                      (with-current-buffer buf-narrow (etaf-web-close)))
                    (when (and (window-live-p w-right) (not (one-window-p t)))
                      (delete-window w-right))))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-links-hoverless-buttons-clickable-and-cached-nav ()
  "Links navigate even on cached pages, hover adds no mouse-face, toolbar buttons are real controls."
  (let* ((cache (make-temp-file "etaf-web-ux-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/list"
                 (list :status "200 OK"
                       :body (concat "<article><h1>Article List</h1>"
                                     "<h3><a href=\"/post\">Read Deep Article</a></h3>"
                                     "<p>Summary text long enough for extraction.</p></article>")))
                ("/post"
                 (list :status "200 OK"
                       :body (concat "<article><h1>Deep Article Body</h1>"
                                     "<p>Full content inside the second page.</p></article>")))
                (_ (list :status "404 Not Found" :body "404"))))
          (let ((u-list (concat base "/list"))
                (u-post (concat base "/post")))
            (setq buf (etaf-web-open u-list))
            (etaf-web-tests--wait-phase buf 'ready)
            (switch-to-buffer buf)
            ;; 1. Zero hover highlight (`mouse-face` nil) on address URL AND reading-view link;
            ;;    disabled Back has no hand pointer; enabled Reload has hand pointer.
            (let ((addr-pos (save-excursion (goto-char (point-min))
                                            (search-forward "http://")
                                            (match-beginning 0)))
                  (link-pos (save-excursion (goto-char (point-min))
                                            (search-forward "Read Deep Article")
                                            (match-beginning 0)))
                  (back-pos (save-excursion (goto-char (point-min))
                                            (search-forward "后退")
                                            (match-beginning 0)))
                  (reload-pos (save-excursion (goto-char (point-min))
                                              (search-forward "刷新")
                                              (match-beginning 0))))
              (should-not (get-text-property addr-pos 'mouse-face))
              (should (eq 'hand (get-text-property addr-pos 'pointer)))
              (should-not (get-text-property link-pos 'mouse-face))
              (should (eq 'hand (get-text-property link-pos 'pointer)))
              (should-not (get-text-property back-pos 'pointer))
              (should (eq 'hand (get-text-property reload-pos 'pointer))))
            ;; 2. Activating address bar enters inline editing directly; ESC cancels cleanly.
            (let ((rt (etaf-runtime-for-buffer buf)))
              (etaf-focus rt 'web-address)
              (execute-kbd-macro (kbd "RET"))
              (should (plist-get (etaf-web-state buf) :address-editing))
              (execute-kbd-macro (kbd "<escape>"))
              (should-not (plist-get (etaf-web-state buf) :address-editing))
              ;; 3. Activating heading link navigates to `/post' and updates rendered body!
              (goto-char (point-min))
              (should (search-forward "Read Deep Article" nil t))
              (goto-char (match-beginning 0))
              (call-interactively (key-binding (kbd "RET")))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u-post)
                                (eq (plist-get st :phase) 'ready))))))
              (let ((body2 (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Full content inside the second page" body2))
                (should-not (string-match-p "Read Deep Article" body2)))
              ;; 4. Back button (`后退') is now enabled with hand pointer and activates via etaf-focus + RET,
              ;;    updating body BACK to Page 1 even though Page 1 is a synchronous cache hit!
              (let ((back-pos (save-excursion (goto-char (point-min))
                                              (search-forward "后退")
                                              (match-beginning 0))))
                (should (eq 'hand (get-text-property back-pos 'pointer))))
              (etaf-focus rt 'web-back)
              (execute-kbd-macro (kbd "RET"))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u-list)
                                (eq (plist-get st :phase) 'ready))))))
              (let ((body-back (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Read Deep Article" body-back))
                (should-not (string-match-p "Full content inside the second page" body-back)))
              ;; 5. Forward button (`前进') is now enabled with hand pointer and returns to cached Page 2!
              (let ((fwd-pos (save-excursion (goto-char (point-min))
                                             (search-forward "前进")
                                             (match-beginning 0))))
                (should (eq 'hand (get-text-property fwd-pos 'pointer))))
              (etaf-focus rt 'web-forward)
              (execute-kbd-macro (kbd "RET"))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u-post)
                                (eq (plist-get st :phase) 'ready))))))
              (let ((body-fwd (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Full content inside the second page" body-fwd))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-toolbar-single-row-and-scrolling ()
  "The toolbar stays one row and the page still scrolls and follows links."
  (let* ((cache (make-temp-file "etaf-web-toolbar-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (long-body (lambda (title link-href link-label)
                      (concat "<article><h1>" title "</h1>"
                              (if link-href
                                  (format "<h3><a href=\"%s\">%s</a></h3>" link-href link-label)
                                "")
                              (mapconcat (lambda (i)
                                           (format "<p>Scrollable line %d of %s with enough prose to pass extraction.</p>"
                                                   i title))
                                         (number-sequence 1 40) "")
                              "</article>")))
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/p1" (list :status "200 OK"
                             :body (funcall long-body "Toolbar One" "/p2" "Jump To Two")))
                ("/p2" (list :status "200 OK"
                             :body (funcall long-body "Toolbar Two" nil nil)))
                (_ (list :status "404 Not Found" :body "404"))))
          (let ((u1 (concat base "/p1"))
                (u2 (concat base "/p2")))
            (setq buf (etaf-web-open u1))
            (etaf-web-tests--wait-phase buf 'ready)
            (switch-to-buffer buf)
            ;; One row of chrome: the toolbar is line 1 and nothing mirrors above it.
            (with-current-buffer buf
              (should (null header-line-format))
              (should (string-match-p "后退" (save-excursion
                                               (goto-char (point-min))
                                               (buffer-substring-no-properties
                                                (line-beginning-position)
                                                (line-end-position)))))
              (should (> (count-lines (point-min) (point-max)) 20)))
            ;; Activate the link through its own mouse-1 binding.
            (let* ((link-pos (save-excursion
                               (goto-char (point-min))
                               (should (search-forward "Jump To Two" nil t))
                               (match-beginning 0)))
                   (km (get-text-property link-pos 'keymap))
                   (m1 (and (keymapp km) (lookup-key km [mouse-1])))
                   (win (get-buffer-window buf t))
                   (ev (list 'mouse-1 (posn-at-point link-pos win))))
              (should (commandp m1))
              (let ((last-input-event ev)
                    (last-command-event ev))
                (funcall m1 ev)))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf)))
                         (and (equal (plist-get st :url) u2)
                              (eq (plist-get st :phase) 'ready))))))
            ;; `C-v' scrolls the page inside its viewport and leaves the toolbar alone.
            (with-current-buffer buf
              (let* ((row1 (lambda ()
                             (save-excursion
                               (goto-char (point-min))
                               (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position)))))
                     (chrome-before (funcall row1))
                     (before (etaf-scroll-offset (etaf-runtime-for-buffer buf) 'web-scroll)))
                (execute-kbd-macro (kbd "C-v"))
                (should (> (etaf-scroll-offset (etaf-runtime-for-buffer buf) 'web-scroll)
                           before))
                (should (equal (funcall row1) chrome-before))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-address-edit-plain-style-and-esc-cg-exit ()
  "Address edit stays 1lh without border color change, exits on ESC/C-g, and preserves link RET."
  (let* ((cache (make-temp-file "etaf-web-edit-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/home"
                 (list :status "200 OK"
                       :body (concat "<article><h1>Home Index</h1>"
                                     "<h3><a href=\"/detail\">Open Detail Article</a></h3>"
                                     "<p>Enough body text for reliable extraction in tests.</p></article>")))
                ("/detail"
                 (list :status "200 OK"
                       :body "<article><h1>Detail Page</h1><p>Reached detail content cleanly.</p></article>"))
                (_ (list :status "404 Not Found" :body "404"))))
          (let ((u-home (concat base "/home"))
                (u-detail (concat base "/detail")))
            (setq buf (etaf-web-open u-home))
            (etaf-web-tests--wait-phase buf 'ready)
            (switch-to-buffer buf)
            (let* ((rt (etaf-runtime-for-buffer buf))
                   (content-line-before
                    (save-excursion
                      (goto-char (point-min))
                      (should (search-forward "Open Detail Article" nil t))
                      (line-number-at-pos)))
                   (border-face-before (get-text-property (point-min) 'face)))
              ;; Enter editing via `g' -> verify constant content line, identical border face,
              ;; no input background fill, and muted hint on the same 1lh row.
              (execute-kbd-macro "g")
              (should (plist-get (etaf-web-state buf) :address-editing))
              (should (etaf-text-input-active-p rt))
              (let ((line1 (buffer-substring-no-properties
                            (point-min)
                            (save-excursion (goto-char (point-min)) (line-end-position))))
                    (content-line-during
                     (save-excursion
                       (goto-char (point-min))
                       (should (search-forward "Open Detail Article" nil t))
                       (line-number-at-pos)))
                    (border-face-during (get-text-property (point-min) 'face)))
                (should (= content-line-during content-line-before))
                (should (equal border-face-during border-face-before))
                (should (string-match-p "RET 打开 · TAB 补全 · ESC 取消" line1)))
              ;; ESC exits editing cleanly and keeps content start line unchanged.
              (execute-kbd-macro [escape])
              (should-not (plist-get (etaf-web-state buf) :address-editing))
              (should-not (etaf-text-input-active-p rt))
              (let ((content-line-after
                     (save-excursion
                       (goto-char (point-min))
                       (should (search-forward "Open Detail Article" nil t))
                       (line-number-at-pos))))
                (should (= content-line-after content-line-before)))
              ;; Re-enter editing via `g' -> C-g stays native `keyboard-quit' AND exits editing!
              (execute-kbd-macro "g")
              (should (plist-get (etaf-web-state buf) :address-editing))
              (should (eq (key-binding (kbd "C-g")) 'keyboard-quit))
              (condition-case nil
                  (execute-kbd-macro (kbd "C-g"))
                (quit nil))
              (should-not (plist-get (etaf-web-state buf) :address-editing))
              (should-not (etaf-text-input-active-p rt))
              ;; Pressing RET even from leading padding on the heading link line navigates reliably!
              (goto-char (point-min))
              (should (search-forward "Open Detail Article" nil t))
              (goto-char (line-beginning-position))
              (execute-kbd-macro (kbd "RET"))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u-detail)
                                (eq (plist-get st :phase) 'ready)))))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-unwraps-chapter-details-and-separates-blocks ()
  "Chapter-level `<details open>' unwraps into headings and blocks while short/closed stay `:::details'."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-reading-quality.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/guide")))
    ;; Chapter-level `<details open>' with heading in `<summary>' unwraps to heading + body.
    (should-not (string-match-p ":::details {title=\"CSS Flexbox Properties\"" md))
    (should (string-match-p "^## CSS Flexbox Properties$" md))
    ;; Short open `<details>' and closed `<details>' stay as `:::details'.
    (should (string-match-p "^:::details {title=\"Short Note\" open=true}$" md))
    (should (string-match-p "^:::details {title=\"Collapsed Reference\" open=false}$" md))
    ;; Blank line separates paragraph, fenced code block, and bullet list.
    (should (string-match-p "New paragraph after double break\\.\n\n```css" md))
    (should (string-match-p "```\n\n- `row`: left to right" md))
    ;; Single `<br>' keeps hard break; double `<br><br>' splits into two paragraphs.
    (should (string-match-p "First line of direction note\\.\\\\\nSecond short line preserved\\.\n\nNew paragraph after double break\\." md))))

(ert-deftest etaf-web-tests-headings-strip-anchors-breaks-and-render-without-underline ()
  "Headings unwrap same-page `#anchor' links and `<br>', and render without underlines while body links stay underlined."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-reading-quality.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/guide")))
    ;; Same-page `#anchor' and `base-url#anchor' inside headings unwrap to plain text;
    ;; `<br>' inside heading turns into a space (no literal backslash).
    (should (string-match-p "^## CSS Flexbox Properties$" md))
    (should-not (string-match-p "\\[CSS Flexbox Properties\\]" md))
    (should (string-match-p "^## Properties for the Parent (Flex Container)$" md))
    (should-not (string-match-p "Parent\\\\" md))
    ;; External heading link remains clickable in Markdown.
    (should (string-match-p "^### \\[External Spec Heading\\](https://example\\.com/spec)$" md))
    ;; Opening the page in `etaf-web-open' renders all headings without underline or bottom rule,
    ;; while keeping external heading links clickable and body links underlined.
    (let* ((cache (make-temp-file "etaf-web-heading-ul-" t))
           (page (expand-file-name "guide.html" cache))
           (buf nil))
      (unwind-protect
          (etaf-web-tests--with-cache cache
            (with-temp-file page (insert html))
            (setq buf (etaf-web-open page))
            (etaf-web-tests--wait-phase buf 'ready)
            (with-current-buffer buf
              (let ((plain (buffer-substring-no-properties (point-min) (point-max))))
                ;; Headings do not render with literal backslashes.
                (should (string-match-p "Properties for the Parent (Flex Container)" plain))
                (should-not (string-match-p "Parent\\\\" plain)))
              ;; External linked heading carries no `:underline' yet stays interactive.
              (cl-labels ((face-underlined-p (f)
                            (cond
                             ((not (listp f)) nil)
                             ((keywordp (car f)) (and (plist-get f :underline) t))
                             (t (cl-some #'face-underlined-p f)))))
                (goto-char (point-min))
                (should (etaf-web-tests--reveal buf "External Spec Heading"))
                (let* ((hpos (match-beginning 0))
                       (hface (get-text-property hpos 'face)))
                  (should-not (face-underlined-p hface))
                  (should (eq 'hand (get-text-property hpos 'pointer))))
                ;; Body paragraph link keeps `:underline'.
                (goto-char (point-min))
                (should (etaf-web-tests--reveal buf "almanac reference"))
                (let* ((bpos (match-beginning 0))
                       (bface (get-text-property bpos 'face)))
                  (should (face-underlined-p bface))))))
        (when (and buf (buffer-live-p buf))
          (with-current-buffer buf (etaf-web-close)))
        (delete-directory cache t)))))

(ert-deftest etaf-web-tests-bounds-image-dimensions-and-tightens-card-grid-gate ()
  "Oversized or percentage images emit responsive Markdown, and imbalanced/heterogeneous grids degrade to normal flow."
  (let* ((html (etaf-web-tests--read-file
                (etaf-web-tests--fixture "layout-reading-quality.html")))
         (md (etaf-web-to-markdown html :base-url "https://example.com/guide")))
    ;; Bounded `width=350' image keeps `<img width="350">'.
    (should (string-match-p "<img src=\"https://example\\.com/assets/flex-dir\\.svg\" alt=\"Flex direction\" width=\"350\">" md))
    ;; Oversized `width=844 height=246' degrades to Markdown image (never emits `width="844"').
    (should (string-match-p "!\\[Wide banner\\](https://example\\.com/assets/wide-banner\\.png)" md))
    (should-not (string-match-p "width=\"844\"" md))
    ;; Percentage `style="width: 100%"' never leaks as pixel `width="100"'.
    (should (string-match-p "!\\[Responsive figure\\](https://example\\.com/assets/responsive\\.png)" md))
    (should-not (string-match-p "width=\"100\"" md))
    ;; Neither the large-image+prose lopsided `.cards` nor heterogeneous `<article>`+`<div>`
    ;; `.cards` becomes a `:::columns` grid; both degrade cleanly to sequential headings & prose.
    (should-not (string-match-p ":::columns" md))
    (should-not (string-match-p ":::card" md))
    (should (string-match-p "^### Tall Diagram & Prose$" md))
    (should (string-match-p "^### Heterogeneous Article$" md))
    (should (string-match-p "^### Heterogeneous Div$" md))))

(ert-deftest etaf-web-tests-noscript-fallback-extracts-ssr-and-rejects-js-stub ()
  "Substantive `<noscript>' SSR content compiles cleanly while JS stubs stay rejected."
  (let* ((ssr-html
          (concat
           "<!DOCTYPE html><html><head><title>Emacs China</title>"
           "<meta name=\"generator\" content=\"Discourse 3.5\"></head>"
           "<body><section id=\"d-splash\"><div class=\"dots\"></div></section>"
           "<script>window.boot = true;</script>"
           "<noscript><div id=\"main-outlet\" role=\"main\">"
           "<script>evilPayload()</script>"
           "<table><thead><tr><th>话题</th><th>回复</th></tr></thead><tbody>"
           "<tr><td><a href=\"/t/emacs-llm/101\">大家平时在 Emacs 里怎么搭配本地模型与知识库一起工作？</a></td><td>24</td></tr>"
           "<tr><td><a href=\"/t/etaf-ui/102\">ETAF 文本应用框架在宽屏与窄屏下的响应式布局实践总结</a></td><td>18</td></tr>"
           "<tr><td><a href=\"javascript:alert(1)\">Bad Link</a></td><td>0</td></tr>"
           "</tbody></table></div></noscript></body></html>"))
         (stub-html
          (concat
           "<!DOCTYPE html><html><head><title>SPA App</title></head>"
           "<body><div id=\"root\"></div><script>boot()</script>"
           "<noscript>Please enable JavaScript to run this application.</noscript>"
           "</body></html>"))
         (ssr-md (etaf-web-to-markdown ssr-html :base-url "https://emacs-china.org/"))
         (stub-md (etaf-web-to-markdown stub-html :base-url "https://spa.example/")))
    ;; Substantive `<noscript>' content compiles and resolves URLs while stripping scripts/javascript:.
    (should (string-match-p "大家平时在 Emacs 里怎么搭配本地模型与知识库一起工作" ssr-md))
    (should (string-match-p "https://emacs-china\\.org/t/emacs-llm/101" ssr-md))
    (should-not (string-match-p "evilPayload" ssr-md))
    (should-not (string-match-p "javascript:" ssr-md))
    ;; JavaScript-required `<noscript>' warning stub is rejected.
    (should-not (string-match-p "Please enable JavaScript" stub-md))))

(ert-deftest etaf-web-tests-adapter-registry-routing-and-mode-override ()
  "Tier 2 adapters claim matching HTML, render ETAF views, and honor mode overrides."
  (let* ((cache (make-temp-file "etaf-web-adapter-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (adapter-name 'test-forum-archetype)
         (disposed nil)
         (buf nil)
         (html (concat
                "<!DOCTYPE html><html><head><title>Community Hub</title>"
                "<meta name=\"generator\" content=\"TestForum 2.0\"></head>"
                "<body><article><h1>Community Hub</h1>"
                "<p>This fallback article paragraph is long enough for Tier 1 reader compilation.</p>"
                "</article></body></html>")))
    (unwind-protect
        (progn
          ;; Validation rejects invalid registrations.
          (should-error (etaf-web-register-adapter :name nil :match-url #'identity :open #'ignore)
                        :type 'etaf-web-error)
          (should-error (etaf-web-register-adapter :name adapter-name :open #'ignore)
                        :type 'etaf-web-error)
          ;; Register Tier 2 adapter matching HTML generator string.
          (should (eq adapter-name
                      (etaf-web-register-adapter
                       :name adapter-name
                       :label "TestForum"
                       :priority 25
                       :match-html (lambda (_url _headers raw _dom)
                                     (and (stringp raw)
                                          (string-match-p "TestForum 2\\.0" raw)))
                       :open (lambda (ctx)
                               (funcall
                                (plist-get ctx :on-ready)
                                (list :title "Community Hub (Adapter)"
                                      :mode-label "TestForum"
                                      :render (lambda (_rctx)
                                                (etaf-node
                                                 'column '(:width stretch :padding ((lh 1) (ch 2)))
                                                 (list (etaf-node 'text nil
                                                                  (list "Tier 2 Adapter Live View")))))
                                      :dispose (lambda () (setq disposed t))))
                               nil))))
          (let ((listed (etaf-web-adapters)))
            (should (cl-some (lambda (d)
                               (and (eq (plist-get d :name) adapter-name)
                                    (equal (plist-get d :label) "TestForum")
                                    (eql (plist-get d :priority) 25)))
                             listed)))
          (etaf-web-tests--with-http base
              (lambda (_m _p) (list :status "200 OK" :body html))
            (setq buf (etaf-web-open (concat base "/forum/")))
            (etaf-web-tests--wait-phase buf 'ready)
            (let ((st (etaf-web-state buf))
                  (txt (with-current-buffer buf
                         (buffer-substring-no-properties (point-min) (point-max)))))
              (should (eq (plist-get st :tier) 't2))
              (should (eq (plist-get st :adapter) adapter-name))
              (should (string-match-p "Tier 2 Adapter Live View" txt))
              (should (string-match-p "TestForum" txt)))
            ;; Switch to `reader' mode: disposes T2 page, persists preference, renders T1 Markdown.
            (with-current-buffer buf
              (should (eq 'reader (etaf-web-set-mode 'reader))))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf)))
                         (and (eq (plist-get st :phase) 'ready)
                              (eq (plist-get st :tier) 't1))))))
            (let ((st (etaf-web-state buf))
                  (txt (with-current-buffer buf
                         (buffer-substring-no-properties (point-min) (point-max)))))
              (should disposed)
              (should (eq (plist-get st :mode) 'reader))
              (should (null (plist-get st :adapter)))
              (should (string-match-p "fallback article paragraph" txt)))
            ;; Switch back to `auto': T2 adapter claims the page again.
            (with-current-buffer buf
              (should (eq 'auto (etaf-web-set-mode 'auto))))
            (should (etaf-web-tests--wait-until
                     (lambda ()
                       (let ((st (etaf-web-state buf)))
                         (and (eq (plist-get st :phase) 'ready)
                              (eq (plist-get st :tier) 't2))))))
            (let ((st (etaf-web-state buf)))
              (should (eq (plist-get st :adapter) adapter-name)))
            ;; Invalid mode signals `etaf-web-error'.
            (with-current-buffer buf
              (should-error (etaf-web-set-mode 'unknown-mode) :type 'etaf-web-error))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (should (etaf-web-unregister-adapter adapter-name))
      (should-not (etaf-web-unregister-adapter adapter-name))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-external-browser-function-handoff ()
  "Configured `etaf-web-external-browser-function' receives handed-off URLs."
  (let* ((cache (make-temp-file "etaf-web-ext-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (handed-off nil)
         (etaf-web-external-browser-function (lambda (url) (push url handed-off)))
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p)
              (list :status "200 OK"
                    :body "<html><head><title>Ext</title></head><body><article><p>A complete sentence for external handoff testing in ETAF Web.</p></article></body></html>"))
          (let ((target (concat base "/handoff")))
            (setq buf (etaf-web-open target))
            (etaf-web-tests--wait-phase buf 'ready)
            (with-current-buffer buf
              (etaf-web-open-external))
            (should (equal handed-off (list target)))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-render-timeout-reports-clear-reason ()
  "A headless renderer that exceeds `etaf-web-render-timeout' reports a timeout reason."
  (let* ((cache (make-temp-file "etaf-web-rto-" t))
         (slow-browser (make-temp-file "etaf-web-slow-browser-" nil ".sh"))
         (old-cmd etaf-web-render-command)
         (old-timeout etaf-web-render-timeout)
         (buf nil))
    (unwind-protect
        (progn
          (with-temp-file slow-browser
            (insert "#!/bin/sh\nsleep 5\n"))
          (set-file-modes slow-browser #o755)
          (setq etaf-web-render-command slow-browser
                etaf-web-render-timeout 0.3)
          (etaf-web-tests--with-cache cache
            (etaf-web-tests--with-http base
                (lambda (_m _p)
                  (list :status "200 OK" :body (etaf-web-tests--short-shell)))
              (setq buf (etaf-web-open (concat base "/slow-spa/")))
              (etaf-web-tests--wait-phase buf 'ready 5.0)
              (let ((txt (with-current-buffer buf
                           (buffer-substring-no-properties (point-min) (point-max)))))
                (should (string-match-p "需要脚本渲染" txt))
                (should (string-match-p "超时" txt))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (setq etaf-web-render-command old-cmd
            etaf-web-render-timeout old-timeout)
      (ignore-errors (delete-file slow-browser))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-loading-progress-patches-toolbar-without-root-rerender ()
  "Loading progress animation ticks patch only `web-status' with zero root rerenders."
  (let* ((cache (make-temp-file "etaf-web-anim-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p)
              (list :status "200 OK" :delay 5.0
                    :body "<article><h1>Slow Page</h1><p>Eventual content.</p></article>"))
          (setq buf (etaf-web-open (concat base "/slow-anim")))
          (should (eq (plist-get (etaf-web-state buf) :phase) 'loading))
          (let* ((rt (etaf-runtime-for-buffer buf))
                 (orig-node (symbol-function 'etaf-node))
                 (node-calls 0)
                 (rev0 (etaf-runtime-revision rt))
                 (prog0 (plist-get (etaf-web-state buf) :progress))
                 (line0 (with-current-buffer buf
                          (save-excursion
                            (goto-char (point-min))
                            (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position)))))
                 (body-line0 (with-current-buffer buf
                               (save-excursion
                                 (goto-char (point-min))
                                 (when (search-forward "正在加载" nil t)
                                   (line-number-at-pos))))))
            ;; Measure across ~5 animation ticks (60 ms interval).
            (cl-letf (((symbol-function 'etaf-node)
                       (lambda (&rest args)
                         (setq node-calls (1+ node-calls))
                         (apply orig-node args))))
              (sleep-for 0.35))
            (let* ((rev1 (etaf-runtime-revision rt))
                   (prog1 (plist-get (etaf-web-state buf) :progress))
                   (rep (etaf-runtime-update-report rt))
                   (line1 (with-current-buffer buf
                            (save-excursion
                              (goto-char (point-min))
                              (buffer-substring-no-properties
                               (line-beginning-position) (line-end-position)))))
                   (body-line1 (with-current-buffer buf
                                 (save-excursion
                                   (goto-char (point-min))
                                   (when (search-forward "正在加载" nil t)
                                     (line-number-at-pos))))))
              ;; Zero root/View rerenders during progress animation ticks.
              (should (= node-calls 0))
              ;; Retained status Host actually updated and toolbar text advanced.
              (should (> rev1 rev0))
              (should (> prog1 prog0))
              (should-not (equal line1 line0))
              (should (string-match-p "[0-9]+%" line1))
              ;; Single-line toolbar height and body start line stayed constant.
              (should (= (cdr (etaf-host-ref-size rt 'web-header)) 1))
              (should (equal body-line1 body-line0))
              (should (eq 'lines (plist-get rep :strategy)))
              (should (= (plist-get rep :edits) 1))
              (should (= (plist-get rep :lines) 1)))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-history-viewport-offset-and-goto-heading ()
  "History Back/Forward restore viewport scroll offset and `etaf-web-goto-heading' scrolls headings into view."
  (let* ((cache (make-temp-file "etaf-web-scrollnav-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (page1
          (concat "<article><h1>Long Guide</h1>"
                  "<h2 id=\"intro\">Intro Section</h2>"
                  (mapconcat (lambda (i)
                               (format "<p>Intro paragraph %d with enough text to scroll well below the fold.</p>" i))
                             (number-sequence 1 18) "")
                  "<h2 id=\"middle\">Middle Section</h2>"
                  "<p>Continue reading at <a href=\"/p2\">Open Second Page</a> now.</p>"
                  (mapconcat (lambda (i)
                               (format "<p>Middle paragraph %d with enough text to push deep heading off screen.</p>" i))
                             (number-sequence 1 26) "")
                  "<h2 id=\"deep\">Deep Target Heading</h2>"
                  (mapconcat (lambda (i)
                               (format "<p>Deep paragraph %d with trailing prose below deep heading.</p>" i))
                             (number-sequence 1 20) "")
                  "</article>"))
         (page2
          (concat "<article><h1>Second Long Page</h1>"
                  (mapconcat (lambda (i)
                               (format "<p>Second page line %d with enough content to be scrollable.</p>" i))
                             (number-sequence 1 35) "")
                  "</article>"))
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/p1" (list :status "200 OK" :body page1))
                ("/p2" (list :status "200 OK" :body page2))
                (_ (list :status "404 Not Found" :body "404"))))
          (let ((u1 (concat base "/p1"))
                (u2 (concat base "/p2")))
            (setq buf (etaf-web-open u1))
            (etaf-web-tests--wait-phase buf 'ready)
            (switch-to-buffer buf)
            (let ((rt (etaf-runtime-for-buffer buf))
                  (mid-offset nil))
              ;; 1. Scroll down to middle section and follow link to Page 2.
              (should (= (etaf-scroll-offset rt 'web-scroll) 0))
              (should (etaf-web-tests--reveal buf "Open Second Page"))
              (setq mid-offset (etaf-scroll-offset rt 'web-scroll))
              (should (> mid-offset 0))
              (goto-char (match-beginning 0))
              (call-interactively (key-binding (kbd "RET")))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u2)
                                (eq (plist-get st :phase) 'ready))))))
              ;; Fresh navigation starts at top of Page 2 (offset 0).
              (should (= (etaf-scroll-offset rt 'web-scroll) 0))
              ;; 2. Back restores exact viewport scroll offset on Page 1.
              (execute-kbd-macro (kbd "M-<left>"))
              (should (etaf-web-tests--wait-until
                       (lambda ()
                         (let ((st (etaf-web-state buf)))
                           (and (equal (plist-get st :url) u1)
                                (eq (plist-get st :phase) 'ready))))))
              (should (= (etaf-scroll-offset rt 'web-scroll) mid-offset))
              (should (string-match-p "Open Second Page"
                                      (buffer-substring-no-properties (point-min) (point-max))))
              ;; 3. `M-x etaf-web-goto-heading' jumps to off-screen Deep Target Heading,
              ;;    making it visible in viewport while keeping line-1 toolbar intact.
              (etaf-scroll-to rt 'web-scroll 0)
              (should-not (string-match-p "Deep Target Heading"
                                          (buffer-substring-no-properties (point-min) (point-max))))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt cands &rest _)
                           (should (assoc "Deep Target Heading" cands))
                           "Deep Target Heading")))
                (call-interactively #'etaf-web-goto-heading))
              (should (> (etaf-scroll-offset rt 'web-scroll) mid-offset))
              (should (looking-at-p "Deep Target Heading"))
              (should (string-match-p "Deep Target Heading"
                                      (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p
                       "后退"
                       (save-excursion
                         (goto-char (point-min))
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-discourse-adapter-list-search-and-thread ()
  "Built-in Discourse Tier 2 adapter renders topic list, handles object tags, and loads thread replies."
  (let* ((cache (make-temp-file "etaf-web-discourse-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil)
         (shell-html
          (concat
           "<!DOCTYPE html><html><head><title>Emacs China</title>"
           "<meta name=\"description\" content=\"可能是最好的 Emacs 中文论坛\">"
           "<meta name=\"generator\" content=\"Discourse 2026.9.0\"></head>"
           "<body><section id=\"d-splash\"></section><script>boot()</script></body></html>"))
         (cats-json
          (json-encode
           '((category_list
              . ((categories
                  . [((id . 7) (name . "闲聊灌水") (slug . "chat") (topic_count . 120) (topics_week . 8)
                      (description_text . "自由讨论"))
                     ((id . 8) (name . "Org-mode") (slug . "org-mode") (topic_count . 95) (topics_week . 5)
                      (description_text . "Org 笔记与大纲"))]))))))
         (latest-json
          (json-encode
           '((users . [((id . 1) (username . "Jamie"))
                       ((id . 2) (username . "dean-chen"))])
             (topic_list
              . ((more_topics_url . "/latest?page=1")
                 (topics
                  . [((id . 32183) (slug . "emacs-llm")
                      (title . "2026 年 Emacs 与 LLM 配合最佳实践")
                      (category_id . 7) (posts_count . 2) (views . 412)
                      (last_poster_username . "Youmu")
                      (last_posted_at . "2026-11-22T00:44:47Z")
                      (posters . [((user_id . 1))])
                      (tags . [((id . 151) (name . "llm") (slug . "llm"))]))
                     ((id . 32179) (slug . "gptel-org")
                      (title . "gptel 在 Org 里和模型交流")
                      (category_id . 8) (posts_count . 5) (views . 337)
                      (last_poster_username . "dean-chen")
                      (last_posted_at . "2026-11-21T10:00:00Z")
                      (posters . [((user_id . 2))])
                      (tags . ["org"]))]))))))
         (thread-json
          (json-encode
           '((id . 32183)
             (title . "2026 年 Emacs 与 LLM 配合最佳实践")
             (category_id . 7) (posts_count . 2) (views . 412)
             (created_at . "2026-11-20T03:17:56Z")
             (tags . [((id . 151) (name . "llm") (slug . "llm"))])
             (post_stream
              . ((stream . [1001 1002])
                 (posts . [((id . 1001) (post_number . 1) (username . "Jamie")
                            (created_at . "2026-11-20T03:17:56Z")
                            (reply_count . 1)
                            (actions_summary . [((id . 2) (count . 4))])
                            (cooked . "<aside class=\"onebox\"><article class=\"onebox-body\"><h3><a href=\"https://github.com/emacs-taf\">emacs-taf</a></h3><p>Short embed summary.</p></article></aside><p>欢迎大家分享今年在 Emacs 中配合大模型的顺手工作流。</p><aside class=\"quote\"><blockquote><p>引用的前楼观点依然完整保留。</p></blockquote></aside><div class=\"lightbox-wrapper\"><a class=\"lightbox\" href=\"https://img.example/original.png\"><img src=\"https://img.example/opt_690x455.png\" alt=\"demo\" width=\"690\" height=\"455\"/><div class=\"meta\"><span class=\"filename\">demo.png</span><span class=\"informations\">1600×900 120 KB</span></div></a></div>"))]))))))
         (more-posts-json
          (json-encode
           '((post_stream
              . ((posts . [((id . 1002) (post_number . 2) (username . "Youmu")
                            (created_at . "2026-11-20T04:00:00Z")
                            (reply_count . 0)
                            (actions_summary . [])
                            (cooked . "<p>我把所有阅读与讨论都留在 ETAF buffer 中完成。</p>"))])))))))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (cond
               ((equal path "/") (list :status "200 OK" :body shell-html))
               ((equal path "/categories.json")
                (list :status "200 OK" :headers "Content-Type: application/json" :body cats-json))
               ((string-prefix-p "/latest.json" path)
                (list :status "200 OK" :headers "Content-Type: application/json" :body latest-json))
               ((equal path "/t/32183.json")
                (list :status "200 OK" :headers "Content-Type: application/json" :body thread-json))
               ((string-prefix-p "/t/32183/posts.json" path)
                (list :status "200 OK" :headers "Content-Type: application/json" :body more-posts-json))
               (t (list :status "404 Not Found" :body "404"))))
          ;; 1. Home page auto-routes to Discourse T2 list view.
          (setq buf (etaf-web-open (concat base "/")))
          (etaf-web-tests--wait-phase buf 'ready)
          (let ((st (etaf-web-state buf))
                (txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't2))
            (should (eq (plist-get st :adapter) 'discourse))
            (should (string-match-p "Discourse" txt))
            (should (string-match-p "2026 年 Emacs 与 LLM" txt))
            (should (string-match-p "配合最佳实践" txt))
            (should (string-match-p "#llm" txt))
            (should-not (string-match-p "(id \\. 151)" txt)))
          ;; 2. Activate first topic row -> opens Discourse Thread view with OP + Load More.
          (with-current-buffer buf
            (switch-to-buffer buf)
            (let ((rt (etaf-runtime-for-buffer buf)))
              (etaf-focus rt 'discourse-topic-0)
              (execute-kbd-macro (kbd "RET"))))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (let ((st (etaf-web-state buf)))
                       (and (string-match-p "/t/emacs-llm/32183" (or (plist-get st :url) ""))
                            (eq (plist-get st :phase) 'ready))))))
          (let ((txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "@Jamie" txt))
            (should (string-match-p "楼主" txt))
            (should (string-match-p "顺手工作流" txt))
            (should (string-match-p "引用的前楼观点依然完整保留" txt))
            (should-not (string-match-p "1600×900" txt)))
          ;; 3. Scroll to load-more button and load remaining floor.
          (with-current-buffer buf
            (let ((rt (etaf-runtime-for-buffer buf)))
              (etaf-scroll-to rt 'web-scroll 10)
              (etaf-runtime-flush rt)
              (should (string-match-p
                       "加载后续 1 楼"
                       (buffer-substring-no-properties (point-min) (point-max))))
              (etaf-focus rt 'discourse-load-more-posts)
              (execute-kbd-macro (kbd "RET"))))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (with-current-buffer buf
                       (let ((rt (etaf-runtime-for-buffer buf)))
                         (etaf-scroll-to rt 'web-scroll 16)
                         (etaf-runtime-flush rt)
                         (string-match-p "@Youmu"
                                         (buffer-substring-no-properties (point-min) (point-max)))))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-docs-adapter-sidebar-tree-drawer-and-prev-next ()
  "Built-in Docs Tier 2 adapter extracts sidebar tree, breadcrumb, and H/L chapter navigation."
  (let* ((cache (make-temp-file "etaf-web-docs-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil)
         (make-doc
          (lambda (title body)
            (concat
             "<!DOCTYPE html><html><head><title>" title "</title>"
             "<meta name=\"generator\" content=\"Astro v7.3\"/>"
             "<meta name=\"generator\" content=\"Starlight v0.42\"/></head>"
             "<body>"
             "<nav class=\"sidebar\" aria-label=\"Main\"><sl-sidebar-state-persist>"
             "<ul><li><details open><summary>Ebox Engine</summary><ul>"
             "<li><a href=\"/docs/intro/\">Introduction</a></li>"
             "<li><a href=\"/docs/layout/\">Box Layout</a></li>"
             "<li><a href=\"/docs/flex/\">Flex Layout</a></li>"
             "<li><a href=\"/docs/flush/\">Incremental Flush</a></li>"
             "</ul></details></li></ul>"
             "</sl-sidebar-state-persist>"
             "<div class=\"md:sl-hidden\"><div class=\"mobile-preferences\">"
             "<a class=\"language-link\" href=\"/zh-cn/docs/intro/\" hreflang=\"zh-CN\">简体中文</a>"
             "</div></div>"
             "</nav>"
             "<main><article><h1>" title "</h1><p>" body "</p>"
             "<div class=\"sl-heading-wrapper level-h2\"><h2 id=\"model\">Model</h2>"
             "<a class=\"sl-anchor-link\" href=\"#model\"><span class=\"sr-only\">Section titled \"Model\"</span></a></div>"
             "<pre data-language=\"elisp\"><code>"
             "<div class=\"ec-line\"><div class=\"code\">(etaf-view</div></div>"
             "<div class=\"ec-line\"><div class=\"code\">  (text \"ok\"))</div></div>"
             "</code></pre>"
             "</article></main>"
             "</body></html>"))))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/docs/intro/"
                 (list :status "200 OK"
                       :body (funcall make-doc "Introduction"
                                      "This introduction chapter explains the retained node tree model thoroughly.")))
                ("/docs/layout/"
                 (list :status "200 OK"
                       :body (funcall make-doc "Box Layout"
                                      "This box layout chapter describes horizontal pixel metrics and line heights.")))
                (_ (list :status "404 Not Found" :body "404"))))
          (setq buf (etaf-web-open (concat base "/docs/intro/")))
          (etaf-web-tests--wait-phase buf 'ready)
          (let ((st (etaf-web-state buf))
                (txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't2))
            (should (eq (plist-get st :adapter) 'docs))
            (should (string-match-p "Ebox Engine  /  Introduction" txt))
            (should (string-match-p "retained node tree model" txt))
            ;; Starlight sr-only heading anchor must not leak into prose.
            (should-not (string-match-p "Section titled" txt))
            ;; Expressive-code multi-line blocks preserve line breaks.
            (should (string-match-p "(etaf-view" txt))
            (should (string-match-p "(text \"ok\"))" txt))
            (should (string-match-p "下一章" txt)))
          ;; Press `L' to jump to the next chapter inferred from sidebar tree order.
          (with-current-buffer buf
            (switch-to-buffer buf)
            (execute-kbd-macro "L"))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (let ((st (etaf-web-state buf)))
                       (and (string-match-p "/docs/layout/" (or (plist-get st :url) ""))
                            (eq (plist-get st :phase) 'ready))))))
          (let ((txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Box Layout" txt))
            (should (string-match-p "上一章" txt))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-live-cdp-auto-escalates-spa-and-handles-interaction ()
  "Pure JS SPA escalates to Tier 3 Live CDP mode and reflects real in-page JS interactions."
  (skip-unless (etaf-web-cdp-available-p))
  (let* ((cache (make-temp-file "etaf-web-live-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (etaf-web-render-command nil)
         (etaf-web-live-enabled t)
         (buf nil)
         (spa-html
          (concat
           "<!doctype html><html><head><meta charset=\"utf-8\"><title>Acme Live SPA</title></head>"
           "<body><div id=\"root\"></div>"
           "<script>"
           "const root = document.getElementById('root');"
           "const rows = ["
           "  {id:'#418', title:'Live CDP Sync Item', open:true},"
           "  {id:'#390', title:'Closed Archived Item', open:false}"
           "];"
           "let cur = 'open';"
           "function draw() {"
           "  const visible = rows.filter(r => cur === 'open' ? r.open : !r.open);"
           "  root.innerHTML = '<aside role=\"navigation\"><a href=\"#issues\">Issues</a></aside>'"
           "    + '<main><h1>Acme Live SPA</h1>'"
           "    + '<input type=\"search\" id=\"q\" placeholder=\"筛选 Issue…\" />'"
           "    + '<div role=\"tablist\">'"
           "    + '<button role=\"tab\" id=\"t-open\" aria-selected=\"' + (cur==='open') + '\">进行中</button>'"
           "    + '<button role=\"tab\" id=\"t-done\" aria-selected=\"' + (cur==='done') + '\">已完成</button>'"
           "    + '</div>'"
           "    + '<table><thead><tr><th>ID</th><th>Title</th></tr></thead><tbody>'"
           "    + visible.map(r => '<tr><td>' + r.id + '</td><td>' + r.title + '</td></tr>').join('')"
           "    + '</tbody></table></main>';"
           "  document.getElementById('t-open').onclick = () => { cur='open'; draw(); };"
           "  document.getElementById('t-done').onclick = () => { cur='done'; draw(); };"
           "}"
           "draw();"
           "</script></body></html>")))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p) (list :status "200 OK" :body spa-html))
          (setq buf (etaf-web-open (concat base "/")))
          (etaf-web-tests--wait-phase buf 'ready 18.0)
          (let ((st (etaf-web-state buf))
                (txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't3))
            (should (string-match-p "Acme Live SPA" txt))
            (should (string-match-p "Live CDP Sync Item" txt))
            (should-not (string-match-p "Closed Archived Item" txt)))
          ;; Activate the `已完成' tab inside the buffer -> real JS updates table to `#390'.
          (with-current-buffer buf
            (switch-to-buffer buf)
            (goto-char (point-min))
            (should (search-forward "已完成" nil t))
            (goto-char (match-beginning 0))
            (call-interactively (key-binding (kbd "RET"))))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (with-current-buffer buf
                       (string-match-p "Closed Archived Item"
                                       (buffer-substring-no-properties (point-min) (point-max)))))
                   8.0)))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (etaf-web-cdp-shutdown)
      (ignore-errors (delete-directory cache t)))))

(ert-deftest etaf-web-tests-embedded-article-and-lightbox-images-preserved ()
  "Embedded `<aside><article>' cards never hijack extraction and lightbox anchors unwrap to block images."
  (let* ((html
          (concat
           "<!doctype html><html><head><title>Framework Overview</title></head><body>"
           "<aside class=\"onebox\"><article class=\"onebox-body\">"
           "<h3><a href=\"https://github.com/emacs-taf\">emacs-taf</a></h3>"
           "<p>Short repository link preview card.</p></article></aside>"
           "<div class=\"post-body\">"
           "<h1>Core Architecture</h1>"
           "<p>ETAF renders interactive text applications inside standard Emacs buffers with incremental layout updates and full theme tokens.</p>"
           "<div class=\"lightbox-wrapper\">"
           "<a class=\"lightbox\" href=\"https://img.example/original/app.png\">"
           "<img src=\"https://img.example/optimized/app_690x455.png\" alt=\"app-shot\" width=\"690\" height=\"455\"/>"
           "</a></div>"
           "<p>Second substantive paragraph confirming the remainder of the document stays intact after an embedded onebox article.</p>"
           "</div></body></html>"))
         (md (etaf-web-to-markdown html :base-url "https://example.org/post")))
    (should (string-match-p "Core Architecture" md))
    (should (string-match-p "incremental layout updates" md))
    (should (string-match-p "Second substantive paragraph" md))
    (should (string-match-p "^!\\[app-shot\\](https://img\\.example/optimized/app_690x455\\.png)$" md))
    (should-not (string-match-p "\\[!\\[app-shot\\]" md))))

(ert-deftest etaf-web-tests-hydrated-content-spa-routes-to-reader-tier ()
  "JS-hydrated blog/content pages route post-hydration to Tier 1 reader instead of Tier 3 live projection."
  (skip-unless (etaf-web-cdp-available-p))
  (let* ((cache (make-temp-file "etaf-web-hyd-blog-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (etaf-web-render-command nil)
         (etaf-web-live-enabled t)
         (buf nil)
         (blog-html
          (concat
           "<!doctype html><html><head><meta charset=\"utf-8\">"
           "<meta name=\"generator\" content=\"VuePress 2.0.0\">"
           "<title>My Engineering Blog</title></head>"
           "<body><header><nav><a href=\"/\">首页</a><a href=\"/about/\">关于</a>"
           "<button type=\"button\">搜索文档</button></nav></header>"
           "<div id=\"app\"><div class=\"vp-post-list\"></div></div>"
           "<script>"
           "const list = document.querySelector('.vp-post-list');"
           "list.innerHTML = '"
           "<div class=\"post-item\"><h2><a href=\"/p/1\">Deterministic Engineering With LLMs</a></h2>"
           "<p>2026-03-16 · AI · 约 2095 字</p>"
           "<p>Practical notes on structuring agent workflows with clear boundaries, repeatable validation gates and maintainable code architecture.</p></div>"
           "<div class=\"post-item\"><h2><a href=\"/p/2\">Understanding Browser Rendering Pipelines</a></h2>"
           "<p>2025-11-10 · 精读 · 约 9831 字</p>"
           "<p>A walkthrough of the critical rendering path from parsed HTML and CSS rules through layout geometry and incremental paint invalidation.</p></div>';"
           "</script></body></html>")))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p) (list :status "200 OK" :body blog-html))
          (setq buf (etaf-web-open (concat base "/")))
          (etaf-web-tests--wait-phase buf 'ready 18.0)
          (let ((st (etaf-web-state buf))
                (txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't1))
            (should (string-match-p "Deterministic Engineering" txt))
            (should (string-match-p "Understanding Browser" txt))
            (should (string-match-p "Rendering Pipelines" txt))
            (should (string-match-p "rendering path" txt))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (etaf-web-cdp-shutdown)
      (ignore-errors (delete-directory cache t)))))

(ert-deftest etaf-web-tests-block-anchors-wrapper-cards-and-inline-boundaries ()
  "HTML5 block anchors, nested-div card headings, CJK streams and inline boundaries compile cleanly."
  (let* ((landing-html
          (concat
           "<!doctype html><html><head><title>Claude 最佳实践 · 中文知识库</title></head>"
           "<body><main>"
           "<section class=\"hero\"><div class=\"eyebrow\">Anthropic Best Practices · 中文整理</div>"
           "<h1>Claude<br><span>最佳实践</span></h1>"
           "<p>231 条官方资源与 100 个概念构成的知识网。</p></section>"
           "<section><h2>五个入口</h2><div class=\"grid\">"
           "<a class=\"card\" href=\"/graph.html\"><div class=\"top\"></div>"
           "<div><h3>交互式知识图谱</h3><p>11 个分类聚类，悬停高亮关联</p></div>"
           "<div class=\"meta\"><span>GRAPH</span><span>/graph.html</span></div></a>"
           "<a class=\"card\" href=\"/mindmap.html\"><div class=\"top\"></div>"
           "<div><h3>思维导图</h3><p>按分类折叠展开的层级导图</p></div>"
           "<div class=\"meta\"><span>MAP</span><span>/mindmap.html</span></div></a>"
           "<a class=\"card\" href=\"/wiki/INDEX.html\"><div class=\"top\"></div>"
           "<div><h3>概念维基</h3><p>100 个原子条目与来源账本</p></div>"
           "<div class=\"meta\"><span>WIKI</span><span>/wiki/INDEX</span></div></a>"
           "</div></section>"
           ;; Standalone block-level anchor outside any grid must NEVER collapse into inline soup.
           "<section><p>独立说明段落，前后夹住一个块级链接卡片。</p>"
           "<a href=\"/deep-dive.html\"><div><h3>独立专题卡片</h3>"
           "<p>即便未命中网格识别，块级链接也应保持标题与正文分行结构。</p></div></a>"
           "</section></main></body></html>"))
         (landing-md (etaf-web-to-markdown landing-html
                                           :base-url "https://example.app/"))
         (stream-html
          (concat
           "<!doctype html><html><head><title>概念索引</title></head><body><main>"
           "<section class=\"cat-block\"><h3>智能体架构<span>13 个概念</span></h3>"
           "<div class=\"idx-row\"><div class=\"t\"><a href=\"/wiki/a\">子代理</a>"
           "<small>Subagents · 专注执行单元</small></div><div class=\"m\"><b>30</b> 篇</div></div>"
           "<div class=\"idx-row\"><div class=\"t\"><a href=\"/wiki/b\">智能体</a>"
           "<small>AI Agent · 自主规划系统</small></div><div class=\"m\"><b>18</b> 篇</div></div>"
           "<div class=\"idx-row\"><div class=\"t\"><a href=\"/wiki/c\">记忆</a>"
           "<small>Memory · 跨运行持久化存储</small></div><div class=\"m\"><b>12</b> 篇</div></div>"
           "</section>"
           "<p><a href=\"/read/1\">构建常驻智能体</a><small>Building always-on agents</small></p>"
           "</main></body></html>"))
         (stream-md (etaf-web-to-markdown stream-html
                                          :base-url "https://example.app/wiki/")))
    ;; Leading hero h1 after short eyebrow is deduplicated.
    (should-not (string-match-p "^# Claude" landing-md))
    ;; 3 block-anchor cards inside `.grid' compile into `:::columns' + `:::card'.
    (should (string-match-p ":::columns {columns=\"3\"" landing-md))
    (should (string-match-p ":::card {title=\"交互式知识图谱\" href=\"https://example\\.app/graph\\.html\"}" landing-md))
    (should (string-match-p ":::card {title=\"概念维基\" href=\"https://example\\.app/wiki/INDEX\\.html\"}" landing-md))
    ;; Standalone block-anchor fallback keeps heading + body block structure.
    (should (string-match-p "^### \\[独立专题卡片\\](https://example\\.app/deep-dive\\.html)$" landing-md))
    (should (string-match-p "^即便未命中网格识别，块级链接也应保持标题与正文分行结构。$" landing-md))
    ;; Section heading + CJK short-title entry stream keeps clean hierarchy without duplicate links.
    (should (string-match-p "^### 智能体架构 13 个概念$" stream-md))
    (should (string-match-p "^#### \\[子代理\\](https://example\\.app/wiki/a)$" stream-md))
    (should (string-match-p "^Subagents · 专注执行单元" stream-md))
    (should-not (string-match-p "\\[子代理\\](https://example\\.app/wiki/a) Subagents" stream-md))
    ;; Visible CJK/Latin boundary across `<a>` + `<small>` inserts a single space.
    (should (string-match-p
             "\\[构建常驻智能体\\](https://example\\.app/read/1) Building always-on agents"
             stream-md))))

(ert-deftest etaf-web-tests-structural-docs-sidebar-without-framework-meta ()
  "Docs Tier 2 adapter recognizes structural `<aside><nav>' chapter trees without framework metadata."
  (let* ((cache (make-temp-file "etaf-web-sdocs-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil)
         (html
          (concat
           "<!doctype html><html><head><title>概念索引 · 知识库</title></head><body>"
           "<aside class=\"side\"><nav class=\"nav\">"
           "<details open><summary>智能体架构</summary><ul>"
           "<li><a href=\"/wiki/subagent.html\">子代理</a></li>"
           "<li><a href=\"/wiki/agent.html\">智能体</a></li>"
           "<li><a href=\"/wiki/memory.html\">记忆</a></li>"
           "<li><a href=\"/wiki/loop.html\">循环</a></li>"
           "</ul></details>"
           "<details><summary>上下文工程</summary><ul>"
           "<li><a href=\"/wiki/context.html\">上下文窗口</a></li>"
           "<li><a href=\"/wiki/prompt.html\">提示工程</a></li>"
           "<li><a href=\"/wiki/compact.html\">上下文压缩</a></li>"
           "<li><a href=\"/wiki/cache.html\">提示缓存</a></li>"
           "</ul></details>"
           "</nav></aside>"
           "<main><article><h1>概念索引</h1>"
           "<p>这是手工编写的静态知识库文档页，没有使用 Starlight 或 VitePress 生成器标记，但具备清晰的双栏导航树与正文区域。</p>"
           "</article></main></body></html>")))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p) (list :status "200 OK" :body html))
          (setq buf (etaf-web-open (concat base "/wiki/subagent.html")))
          (etaf-web-tests--wait-phase buf 'ready)
          (let ((st (etaf-web-state buf))
                (txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't2))
            (should (eq (plist-get st :adapter) 'docs))
            (should (string-match-p "智能体架构" txt))
            (should (string-match-p "手工编写的静态知识库文档页" txt))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-custom-element-tables-article-lists-and-docs-sidebars ()
  "Custom block wrappers keep tables intact, primary link lists survive, sparse layout tables unwrap, cite_note footnotes resolve, and nested VitePress/MkDocs sidebars extract all chapters."
  (let* ((readme-html
          (concat
           "<!doctype html><html><head><title>Tool README</title></head><body>"
           "<article><h2>Quick links</h2>"
           "<ul><li><a href=\"/install\">Install</a></li>"
           "<li><a href=\"/guide\">Guide</a></li>"
           "<li><a href=\"/faq\">FAQ</a></li></ul>"
           "<markdown-accessiblity-table><table><thead><tr><th>Tool</th><th>Time</th></tr></thead>"
           "<tbody><tr><td>rg</td><td>0.08s</td></tr></tbody></table></markdown-accessiblity-table>"
           "<p>History note.<sup class=\"reference\"><a href=\"#cite_note-1\">[1]</a></sup></p>"
           "<ol><li id=\"cite_note-1\">Original archival reference.</li></ol>"
           "</article></body></html>"))
         (readme-md (etaf-web-to-markdown readme-html :base-url "https://example.org/repo"))
         (hn-html
          (concat
           "<!doctype html><html><head><title>News Portal</title></head><body>"
           "<table>"
           "<tr><td>1.</td><td></td><td><a href=\"https://a.test\">Story One</a></td></tr>"
           "<tr><td></td><td></td><td>100 points by alice</td></tr>"
           "<tr><td></td><td></td><td></td></tr>"
           "<tr><td>2.</td><td></td><td><a href=\"https://b.test\">Story Two</a></td></tr>"
           "<tr><td></td><td></td><td>80 points by bob</td></tr>"
           "<tr><td></td><td></td><td></td></tr>"
           "</table></body></html>"))
         (hn-md (etaf-web-to-markdown hn-html :base-url "https://news.example/"))
         (cache (make-temp-file "etaf-web-vpdocs-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf nil)
         (vp-html
          (concat
           "<!doctype html><html><head><title>Guide | Docs</title></head><body>"
           "<aside class=\"VPSidebar\"><nav id=\"VPSidebarNav\">"
           "<section class=\"VPSidebarItem\"><div><h2>Introduction</h2></div>"
           "<ul><li>"
           "<div><a href=\"/guide/intro\">What is It?</a></div>"
           "<div><a href=\"/guide/start\">Getting Started</a></div>"
           "<div><a href=\"/guide/routing\">Routing</a></div>"
           "<div><a href=\"/guide/deploy\">Deploy</a></div>"
           "<div><a href=\"/guide/config\">Configuration</a></div>"
           "</li></ul></section>"
           "</nav></aside>"
           "<main><article><h1>What is It?</h1>"
           "<p>A thorough guide covering routing, deployment and configuration for static documentation sites.</p>"
           "</article></main></body></html>")))
    ;; Custom-element wrapped table stays a GFM pipe table, primary link list survives, cite_note resolves.
    (should (string-match-p "^- \\[Install\\](https://example\\.org/install)$" readme-md))
    (should (string-match-p "^| Tool | Time |$" readme-md))
    (should (string-match-p "^| rg | 0\\.08s |$" readme-md))
    (should (string-match-p "\\[\\^1\\]" readme-md))
    (should (string-match-p "^\\[\\^1\\]: Original archival reference\\.$" readme-md))
    ;; Sparse headerless layout table unwraps cleanly instead of emitting a sparse pipe table.
    (should (string-match-p "^1\\. \\[Story One\\](https://a\\.test)$" hn-md))
    (should-not (string-match-p "^| 1\\." hn-md))
    ;; VitePress single-<li> multi-link section extracts all 5 chapters into Tier 2 Docs sidebar.
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p) (list :status "200 OK" :body vp-html))
          (setq buf (etaf-web-open (concat base "/guide/intro")))
          (etaf-web-tests--wait-phase buf 'ready)
          (let ((st (etaf-web-state buf))
                (txt (with-current-buffer buf
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't2))
            (should (eq (plist-get st :adapter) 'docs))
            (should (string-match-p "Introduction" txt))
            (should (string-match-p "Getting Started" txt))
            (should (string-match-p "Configuration" txt))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-mathml-editsection-discussion-and-nextra-docs ()
  "MathML compiles to LaTeX, MediaWiki editsection drops cleanly, discussion comment trees survive, multi-class docs sidebars route to Docs while PyPI metadata sidebars stay T1, and embedded `:::tip' renders as an alert."
  (let* ((paper-html
          (concat
           "<!doctype html><html><head><title>Paper</title></head><body><article>"
           "<div class=\"mw-heading\"><h2>History</h2>"
           "<span class=\"mw-editsection\"><span class=\"mw-editsection-bracket\">[</span>"
           "<a href=\"/edit\">edit</a><span class=\"mw-editsection-bracket\">]</span></span></div>"
           "<p>Vectors of dimension <math display=\"inline\"><semantics>"
           "<msub><mi>d</mi><mi>k</mi></msub>"
           "<annotation encoding=\"application/x-tex\">d_{k}</annotation></semantics></math>.</p>"
           "<math display=\"block\" alttext=\"Q K^{T}\"><mrow><mi>Q</mi></mrow></math>"
           "<p><a href=\"/start\">Get started</a><button>Quick search</button><kbd>K</kbd></p>"
           "</article></body></html>"))
         (paper-md (etaf-web-to-markdown paper-html :base-url "https://example.org/paper"))
         (thread-html
          (concat
           "<!doctype html><html><head><title>Discussion</title></head><body>"
           "<table><tr><td><a href=\"https://app.test\">Launch App</a></td></tr></table>"
           "<table class=\"comment-tree\"><tr><td class=\"commtext\">"
           "<p>" (make-string 180 ?a) " first detailed community comment with substantial technical discussion about systems engineering and design tradeoffs.</p>"
           "<p>" (make-string 180 ?b) " second detailed follow-up comment explaining edge cases, latency measurements and deployment architecture in full.</p>"
           "</td></tr></table></body></html>"))
         (thread-md (etaf-web-to-markdown thread-html :base-url "https://news.example/item?id=1"))
         (cache (make-temp-file "etaf-web-nextra-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf1 nil)
         (buf2 nil)
         (nextra-html
          (concat
           "<!doctype html><html><head><title>Nextra Guide</title></head><body>"
           "<aside class=\"nextra-sidebar x:flex x:flex-col\"><ul>"
           "<li><a href=\"/docs/intro\">Intro</a></li>"
           "<li><a href=\"/docs/routing\">Routing</a></li>"
           "<li><a href=\"/docs/mdx\">MDX</a></li>"
           "<li><a href=\"/docs/themes\">Themes</a></li>"
           "<li><a href=\"/docs/deploy\">Deploy</a></li>"
           "</ul></aside>"
           "<main><article><h1>Nextra Guide</h1>"
           "<div class=\"callout tip\"><p>Skip ahead to the quickstart guide.</p></div>"
           "<details><summary>Can I use MDX?</summary><p>Yes with Nextra 4.</p></details>"
           "<p>Comprehensive static site documentation content explaining file-system routing and custom components.</p>"
           "</article></main></body></html>"))
         (pypi-html
          (concat
           "<!doctype html><html><head><title>pkg · PyPI</title></head><body>"
           "<div class=\"project-description__sidebar\"><ul>"
           "<li><a href=\"/search/?c=Python+3\">Python 3</a></li>"
           "<li><a href=\"/search/?c=MIT\">MIT</a></li>"
           "<li><a href=\"/search/?c=Web\">Web</a></li>"
           "<li><a href=\"/search/?c=HTTP\">HTTP</a></li>"
           "<li><a href=\"/search/?c=API\">API</a></li>"
           "</ul></div>"
           "<main><article><h1>pkg</h1>"
           "<p>A concise Python HTTP library for humans with session pooling, TLS verification and streaming downloads.</p>"
           "</article></main></body></html>")))
    ;; MathML -> native LaTeX without doubled text, editsection stripped, button/kbd spaced.
    (should (string-match-p "^## History$" paper-md))
    (should-not (string-match-p "\\[edit\\]" paper-md))
    (should (string-match-p "dimension \\$d_{k}\\$" paper-md))
    (should-not (string-match-p "dkd_{k}" paper-md))
    (should (string-match-p "^\\$\\$\nQ K\\^{T}\n\\$\\$$" paper-md))
    (should (string-match-p "\\[Get started\\](https://example\\.org/start) Quick search :kbd\\[K\\]" paper-md))
    ;; Dedicated comment-tree page preserves discussion comments.
    (should (string-match-p "first detailed community comment" thread-md))
    (should (string-match-p "second detailed follow-up comment" thread-md))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/docs/intro" (list :status "200 OK" :body nextra-html))
                ("/project/pkg/" (list :status "200 OK" :body pypi-html))
                (_ (list :status "404 Not Found" :body "404"))))
          ;; Multi-class `nextra-sidebar x:flex' routes to Tier 2 Docs and renders callout alert natively.
          (setq buf1 (etaf-web-open (concat base "/docs/intro")))
          (etaf-web-tests--wait-phase buf1 'ready)
          (let ((st (etaf-web-state buf1))
                (txt (with-current-buffer buf1
                       (buffer-substring-no-properties (point-min) (point-max)))))
            (should (eq (plist-get st :tier) 't2))
            (should (eq (plist-get st :adapter) 'docs))
            (should (string-match-p "提示" txt))
            (should-not (string-match-p ":::tip" txt))
            (should (string-match-p "Can I use MDX\\?" txt))
            (should (string-match-p "Yes with Nextra 4\\." txt))
            (should-not (string-match-p ":::details" txt)))
          ;; PyPI metadata sidebar with `/search/?c=' links stays Tier 1 Reader.
          (setq buf2 (etaf-web-open (concat base "/project/pkg/")))
          (etaf-web-tests--wait-phase buf2 'ready)
          (let ((st (etaf-web-state buf2)))
            (should (eq (plist-get st :tier) 't1))
            (should-not (plist-get st :adapter))))
      (when (and buf1 (buffer-live-p buf1))
        (with-current-buffer buf1 (etaf-web-close)))
      (when (and buf2 (buffer-live-p buf2))
        (with-current-buffer buf2 (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-live-cdp-input-stability-and-custom-checkbox ()
  "JS-required stub notices escalate to T3, multi-char input keeps focus, app-shell siblings survive, and opacity:0 checkboxes toggle live."
  (skip-unless (etaf-web-cdp-available-p))
  (let* ((cache (make-temp-file "etaf-web-t3todo-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (etaf-web-render-command nil)
         (etaf-web-live-enabled t)
         (buf nil)
         (todo-html
          (concat
           "<!doctype html><html><head><meta charset=\"utf-8\"><title>Mini Todo</title>"
           "<style>.toggle{opacity:0;width:20px;height:20px;}</style></head><body>"
           "<noscript>This page will only work with JavaScript enabled</noscript>"
           "<div id=\"root\"></div>"
           "<script>"
           "const root = document.getElementById('root');"
           "const items = [];"
           "function draw() {"
           "  root.innerHTML = '<section class=\"todoapp\">'"
           "    + '<header><h1>todos</h1><input id=\"new\" placeholder=\"Add task\" /></header>'"
           "    + (items.length ? '<main><ul>' + items.map((it,i) =>"
           "        '<li><input class=\"toggle\" type=\"checkbox\" data-i=\"'+i+'\"'+(it.done?' checked':'')+'/><label>'+it.text+'</label></li>').join('') + '</ul></main>'"
           "      + '<footer><span>' + items.filter(x=>!x.done).length + ' left</span></footer>' : '')"
           "    + '</section>';"
           "  const inp = document.getElementById('new');"
           "  inp.addEventListener('keydown', (e) => {"
           "    if (e.key === 'Enter' && inp.value.trim()) { items.push({text: inp.value.trim(), done: false}); draw(); }"
           "  });"
           "  root.querySelectorAll('.toggle').forEach((cb) => {"
           "    cb.addEventListener('change', () => { items[Number(cb.dataset.i)].done = cb.checked; draw(); });"
           "  });"
           "}"
           "draw();"
           "</script></body></html>")))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m _p) (list :status "200 OK" :body todo-html))
          (setq buf (etaf-web-open (concat base "/")))
          (etaf-web-tests--wait-phase buf 'ready 18.0)
          (should (eq (plist-get (etaf-web-state buf) :tier) 't3))
          ;; Multi-character typing must NOT lose focus on character 1 when clear button mounts.
          (with-current-buffer buf
            (switch-to-buffer buf)
            (goto-char (point-min))
            (should (search-forward "Add task" nil t))
            (goto-char (match-beginning 0))
            (execute-kbd-macro (kbd "RET"))
            (execute-kbd-macro "Ship ETAF")
            (execute-kbd-macro (kbd "RET")))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (with-current-buffer buf
                       (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                         (and (string-match-p "\\[ \\] Ship ETAF" txt)
                              (string-match-p "1 left" txt)
                              (string-match-p "Add task" txt)))))
                   8.0))
          ;; Second submission after `<main>' mounts must remain interactive (no ref collision).
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "Add task" nil t))
            (goto-char (match-beginning 0))
            (execute-kbd-macro (kbd "RET"))
            (execute-kbd-macro "Second item")
            (execute-kbd-macro (kbd "RET")))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (with-current-buffer buf
                       (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                         (and (string-match-p "\\[ \\] Second item" txt)
                              (string-match-p "2 left" txt)))))
                   8.0))
          ;; Toggle opacity:0 custom checkbox -> live DOM updates to `1 left' and `[x] Ship ETAF'.
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "[ ] Ship ETAF" nil t))
            (goto-char (match-beginning 0))
            (execute-kbd-macro (kbd "RET")))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (with-current-buffer buf
                       (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                         (and (string-match-p "\\[x\\] Ship ETAF" txt)
                              (string-match-p "1 left" txt)))))
                   8.0)))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (etaf-web-cdp-shutdown)
      (ignore-errors (delete-directory cache t)))))

(ert-deftest etaf-web-tests-wave2-extraction-routing-and-http-negotiation ()
  "Wave-2 universal fixes: drop `<select>' options, preserve `shared__*' & `<main>' discussions, deduplicate MediaWiki references, bind block-anchor `<article><h2>' links, extract multi-article feeds & OP+replies, reject news/header nav from Tier 2 Docs, and report challenge HTTP 403 cleanly."
  (let* (;; 1. `<select>` dropdowns drop cleanly so search results win Readability.
         (ddg-html
          (concat
           "<!doctype html><html><head><title>Search</title></head><body>"
           "<div id=\"header\"><form><select name=\"kl\">"
           "<option>All Regions</option><option>Argentina</option><option>Australia</option>"
           "<option>Austria</option><option>Belgium</option><option>Brazil</option>"
           "<option>Canada</option><option>China</option><option>France</option>"
           "<option>Germany</option><option>Japan</option></select></form></div>"
           "<div id=\"links\"><div class=\"result\"><h2><a href=\"https://gnu.org/emacs\">GNU Emacs</a></h2>"
           "<p>GNU Emacs is an extensible, customizable, self-documenting text editor with Lisp.</p></div>"
           "<div class=\"result\"><h2><a href=\"https://etaf.top/\">ETAF Framework</a></h2>"
           "<p>Text application framework for Emacs with reactive components and layout engine.</p></div></div>"
           "</body></html>"))
         (ddg-md (etaf-web-to-markdown ddg-html :base-url "https://search.example/?q=emacs"))
         ;; 2. `<main>` GitHub-style issue preserves `shared__*` & `commentsContainer` comments.
         (issue-html
          (concat
           "<!doctype html><html><head><title>Issue #1</title></head><body>"
           "<main id=\"repo-main\"><h1>Add UTF-16 encoding support</h1>"
           "<div class=\"commentsContainer__BJKxiK\">"
           "<div class=\"shared__KSUE2D\"><p>"
           (make-string 220 ?x) " opening issue description covering encoding auto-detection and BOM handling.</p></div>"
           "<div class=\"shared__KSUE2D\"><p>"
           (make-string 220 ?y) " follow-up maintainer reply explaining streaming decoder performance benchmarks.</p></div>"
           "</div></main></body></html>"))
         (issue-md (etaf-web-to-markdown issue-html :base-url "https://code.example/org/repo/issues/1"))
         ;; 3. Wikipedia `<ol class="references">` moves to footnotes once and drops empty `## References`.
         (wiki-html
          (concat
           "<!doctype html><html><head><title>Emacs Lisp</title></head><body><main>"
           "<p>Emacs Lisp is a dialect of Lisp<sup class=\"reference\"><a href=\"#cite_note-1\">[1]</a></sup> used by GNU Emacs.</p>"
           "<h2>References</h2>"
           "<div class=\"mw-references-wrap\"><ol class=\"references\">"
           "<li id=\"cite_note-1\"><a href=\"#cite_ref-1\">^</a> GNU Emacs Manual reference entry.</li>"
           "</ol></div>"
           "<h2>External links</h2><ul><li><a href=\"https://gnu.org\">Official website</a></li></ul>"
           "</main></body></html>"))
         (wiki-md (etaf-web-to-markdown wiki-html :base-url "https://en.wikipedia.org/wiki/Emacs_Lisp"))
         ;; 4. Block-anchor `<a href><article><h2>` binds link + long prose anchor avoids giant link.
         (blog-html
          (concat
           "<!doctype html><html><head><title>Blog</title></head><body><main>"
           "<a href=\"/post-one/\"><article><h2>First Post Title</h2><p>Short summary of post one.</p></article></a>"
           "<a href=\"/long-note/\"><div><p>"
           (make-string 260 ?z) " long community note wrapped in a single block anchor.</p></div></a>"
           "</main></body></html>"))
         (blog-md (etaf-web-to-markdown blog-html :base-url "https://blog.example/"))
         ;; 5. Forum OP `<h1>` + replies container keeps BOTH OP and replies.
         (forum-html
          (concat
           "<!doctype html><html><head><title>Forum Topic</title></head><body>"
           "<div id=\"Main\">"
           "<div class=\"box\"><h1>如何从零构建编辑器</h1>"
           "<p>想请教各位在架构设计与渲染性能方面的实战经验。</p></div>"
           "<div id=\"topic-replies\">"
           "<div class=\"cell\"><p>第一条详细中文回复，介绍数据结构和增量更新机制，非常实用。</p></div>"
           "<div class=\"cell\"><p>第二条详细中文回复，补充测试基准与布局缓存策略，避免卡顿。</p></div>"
           "<div class=\"cell\"><p>第三条详细中文回复，分析事件分发与焦点管理边界条件，值得参考。</p></div>"
           "<div class=\"cell\"><p>第四条详细中文回复，对比不同渲染架构在长文档下的帧率与内存表现。</p></div>"
           "</div></div></body></html>"))
         (forum-md (etaf-web-to-markdown forum-html :base-url "https://forum.example/t/1"))
         ;; 6. News site `<header><nav aria-label="Main navigation">` must NOT route to Tier 2 Docs.
         (news-html
          (concat
           "<!doctype html><html><head><title>World News</title></head><body>"
           "<header><nav id=\"main-navigation\" aria-label=\"Main navigation\"><ul>"
           "<li><a href=\"/world\">World</a></li><li><a href=\"/tech\">Tech</a></li>"
           "<li><a href=\"/science\">Science</a></li><li><a href=\"/business\">Business</a></li>"
           "<li><a href=\"/culture\">Culture</a></li><li><a href=\"/sport\">Sport</a></li>"
           "</ul></nav></header>"
           "<main><article><h1>Breaking Tech Headline</h1>"
           "<p>Full journalism story covering global technology developments with detailed analysis and interviews.</p>"
           "</article></main></body></html>"))
         (cache (make-temp-file "etaf-web-wave2-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (buf-news nil)
         (buf-chal nil))
    ;; Assertions 1-5: compilation
    (should-not (string-match-p "Argentina" ddg-md))
    (should (string-match-p "GNU Emacs" ddg-md))
    (should (string-match-p "ETAF Framework" ddg-md))
    (should (string-match-p "opening issue description" issue-md))
    (should (string-match-p "follow-up maintainer reply" issue-md))
    (should (string-match-p "\\[\\^1\\]: GNU Emacs Manual reference entry\\." wiki-md))
    (should-not (string-match-p "^## References$" wiki-md))
    (should-not (string-match-p "^1\\. " wiki-md))
    (should (string-match-p "^## \\[First Post Title\\](https://blog\\.example/post-one/)$" blog-md))
    (should (string-match-p "\\[查看详情\\](https://blog\\.example/long-note/)" blog-md))
    (should (string-match-p "如何从零构建编辑器" forum-md))
    (should (string-match-p "第一条详细中文回复" forum-md))
    (should (string-match-p "第四条详细中文回复" forum-md))
    ;; Assertions 6-7: Docs false-positive guard & HTTP 403 Challenge diagnostic
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/news" (list :status "200 OK" :body news-html))
                ("/blocked"
                 (list :status "403 Forbidden"
                       :headers '("cf-mitigated: challenge")
                       :body "<!doctype html><html><head><title>Just a moment...</title></head><body>Enable JavaScript and cookies to continue</body></html>"))
                (_ (list :status "404 Not Found" :body "404"))))
          (setq buf-news (etaf-web-open (concat base "/news")))
          (etaf-web-tests--wait-phase buf-news 'ready)
          (let ((st (etaf-web-state buf-news)))
            (should (eq (plist-get st :tier) 't1))
            (should-not (plist-get st :adapter)))
          (setq buf-chal (etaf-web-open (concat base "/blocked")))
          (etaf-web-tests--wait-phase buf-chal 'error)
          (let* ((err-obj (plist-get (etaf-web-state buf-chal) :error))
                 (err-msg (or (and (listp err-obj) (plist-get err-obj :message))
                              (and (stringp err-obj) err-obj)
                              "")))
            (should (string-match-p "Challenge\\|安全验证" err-msg))))
      (when (and buf-news (buffer-live-p buf-news))
        (with-current-buffer buf-news (etaf-web-close)))
      (when (and buf-chal (buffer-live-p buf-chal))
        (with-current-buffer buf-chal (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-four-layer-code-language-detection ()
  "Four-layer language identification covers DOM wrappers, aliases, deterministic anchors, margin-gated scoring and plain-text safety."
  (let* ((html
          (concat
           "<!doctype html><html><head><title>Effective Go Guide</title></head><body><main><article>"
           "<h1>Code Language Identification</h1>"
           ;; Layer 1: Sphinx grandparent wrapper + Python3 normalization.
           "<div class=\"highlight-python3 notranslate\"><div class=\"highlight\"><pre><span>x = 1</span></pre></div></div>"
           ;; Layer 1: GitHub wrapper class `highlight-source-shell'.
           "<div class=\"highlight highlight-source-shell\"><pre>echo hi</pre></div>"
           ;; Layer 1: Rustdoc bare class `rust item-decl'.
           "<pre class=\"rust item-decl\"><code>pub struct Demo;</code></pre>"
           ;; Layer 1: PyPI HTML `lang' attribute.
           "<pre lang=\"python\"><code>import requests</code></pre>"
           ;; Layer 1: VitePress `language-template' -> `html'.
           "<div class=\"language-template\"><pre><code>&lt;div id=\"app\"&gt;ok&lt;/div&gt;</code></pre></div>"
           ;; Layer 1: Sibling filename caption `<figcaption>app.ts</figcaption>'.
           "<figure><figcaption>app.ts</figcaption><pre><code>const n = 1</code></pre></figure>"
           ;; Layer 1: Explicit plain-text / ASCII art lock (must stay `text').
           "<div class=\"art-ascii-art\"><pre>GET / HTTP/1.1\nHost: example.com</pre></div>"
           "<div class=\"language-text\"><pre><code>brew install ripgrep</code></pre></div>"
           ;; Layer 3: Deterministic anchors on bare `<pre>'.
           "<pre>#!/usr/bin/env python3\nprint('hi')</pre>"
           "<pre>{\"name\": \"etaf\", \"count\": 3}</pre>"
           "<pre>diff --git a/a.el b/a.el\n--- a/a.el\n+++ b/a.el\n@@ -1 +1 @@\n-old\n+new</pre>"
           "<pre>GET /index.html HTTP/1.1\nHost: example.org\nAccept: text/html</pre>"
           "<pre>SELECT id, name FROM users WHERE active = 1;</pre>"
           "<pre>(add-hook 'prog-mode-hook #'display-line-numbers-mode)</pre>"
           "<pre>$ git status -sb\nM README.md</pre>"
           "<pre>brew install ripgrep</pre>"
           "<pre>FROM alpine:3.20\nRUN apk add git</pre>"
           ;; Layer 4: Margin-gated weighted scoring on bare `<pre>'.
           "<pre>type Server struct {\n    addr string\n}\nfunc (s *Server) Start() error {\n    err := s.listen()\n    if err != nil {\n        return err\n    }\n    return nil\n}</pre>"
           "<pre>function MyButton() {\n  const [count, setCount] = useState(0);\n  return (&lt;button onClick={() =&gt; setCount(count + 1)}&gt;Click&lt;/button&gt;);\n}</pre>"
           "<pre>@theme {\n  --font-sans: \"Inter\", sans-serif;\n}\nbody {\n  display: flex;\n  margin: 1em;\n}</pre>"
           ;; Non-code safety: Emacs keybinding, ASCII diagram, plain prose MUST stay `text'.
           "<pre>C-x C-f /sudo::/etc/hosts</pre>"
           "<pre>UA =========== A =========== B</pre>"
           "<pre>Rust is installed now. Great!</pre>"
           "</article></main></body></html>"))
         (md (etaf-web-to-markdown html :base-url "https://go.dev/doc/effective_go")))
    ;; Layer 1 & 2 expectations.
    (should (string-match-p "```python\nx = 1\n```" md))
    (should (string-match-p "```shell\necho hi\n```" md))
    (should (string-match-p "```rust\npub struct Demo;\n```" md))
    (should (string-match-p "```python\nimport requests\n```" md))
    (should (string-match-p "```html\n<div id=\"app\">ok</div>\n```" md))
    (should (string-match-p "```ts\nconst n = 1\n```" md))
    ;; Explicit plain locks stay `text'.
    (should (string-match-p "```text\nGET / HTTP/1\\.1\nHost: example\\.com\n```" md))
    (should (string-match-p "```text\nbrew install ripgrep\n```" md))
    ;; Layer 3 deterministic anchors.
    (should (string-match-p "```python\n#!/usr/bin/env python3\nprint('hi')\n```" md))
    (should (string-match-p "```json\n{\"name\": \"etaf\", \"count\": 3}\n```" md))
    (should (string-match-p "```diff\ndiff --git a/a\\.el b/a\\.el" md))
    (should (string-match-p "```http\nGET /index\\.html HTTP/1\\.1\nHost: example\\.org" md))
    (should (string-match-p "```sql\nSELECT id, name FROM users WHERE active = 1;\n```" md))
    (should (string-match-p "```elisp\n(add-hook 'prog-mode-hook #'display-line-numbers-mode)\n```" md))
    (should (string-match-p "```sh\n\\$ git status -sb\nM README\\.md\n```" md))
    (should (string-match-p "```sh\nbrew install ripgrep\n```" md))
    (should (string-match-p "```dockerfile\nFROM alpine:3\\.20\nRUN apk add git\n```" md))
    ;; Layer 4 scored detection.
    (should (string-match-p "```go\ntype Server struct {" md))
    (should (string-match-p "```jsx\nfunction MyButton()" md))
    (should (string-match-p "```css\n@theme {" md))
    ;; Non-code safety stays `text'.
    (should (string-match-p "```text\nC-x C-f /sudo::/etc/hosts\n```" md))
    (should (string-match-p "```text\nUA =========== A =========== B\n```" md))
    (should (string-match-p "```text\nRust is installed now\\. Great!\n```" md))))

(ert-deftest etaf-web-tests-visible-cursor-movement-selection-and-copy ()
  "Rendered web pages keep a visible cursor, support normal cursor motion with viewport auto-scroll, allow native mark/copy, and preserve safe RET and URL copy."
  (let* ((cache (make-temp-file "etaf-web-cursor-" t))
         (etaf-web-cache-directory cache)
         (etaf-web-download-images nil)
         (transient-mark-mode t)
         (paras (mapconcat
                 (lambda (i)
                   (format "<p>Paragraph %02d alpha beta gamma delta epsilon.</p>" i))
                 (number-sequence 1 40) "\n"))
         (page1 (concat "<!doctype html><html><head><title>Cursor Page</title></head><body>"
                        "<main><article><h1>Cursor Navigation Heading</h1>"
                        "<p>Visit <a href=\"/target\">Target Destination</a> right now.</p>"
                        paras
                        "</article></main></body></html>"))
         (page2 (concat "<!doctype html><html><head><title>Target Page</title></head><body>"
                        "<main><article><h1>Arrived At Target</h1>"
                        "<p>Successfully navigated via RET at cursor.</p>"
                        "</article></main></body></html>"))
         (buf nil))
    (unwind-protect
        (etaf-web-tests--with-http base
            (lambda (_m path)
              (pcase path
                ("/page1" (list :status "200 OK" :body page1))
                ("/target" (list :status "200 OK" :body page2))
                (_ (list :status "404 Not Found" :body "404"))))
          (setq buf (etaf-web-open (concat base "/page1")))
          (etaf-web-tests--wait-phase buf 'ready)
          (with-current-buffer buf
            (set-window-buffer (selected-window) buf)
            ;; 1. Cursor stays visible and modality auto-hide is disabled.
            (should (not etaf-cursor-follows-input-modality))
            (should cursor-type)
            (let ((last-command-event '(mouse-1)))
              (run-hooks 'pre-command-hook))
            (should cursor-type)
            ;; 2. Initial cursor lands inside the rendered page body (> line 1).
            (let ((init-line (line-number-at-pos (point))))
              (should (> init-line 1)))
            ;; 3. C-f / C-b and <right> / <left> move character-by-character.
            (let ((p0 (point)))
              (execute-kbd-macro (kbd "C-f C-f"))
              (should (= (point) (+ p0 2)))
              (execute-kbd-macro (kbd "C-b"))
              (should (= (point) (+ p0 1)))
              (execute-kbd-macro (kbd "<right>"))
              (should (= (point) (+ p0 2)))
              (execute-kbd-macro (kbd "<left> <left>"))
              (should (= (point) p0)))
            ;; 4. C-a / C-e jump to text start/end on the current line (C-a toggles to BOL).
            (execute-kbd-macro (kbd "C-f C-f C-a"))
            (let ((bol-text (point)))
              (should (not (memq (char-after bol-text) '(?\s ?\t ?\n))))
              (execute-kbd-macro (kbd "C-e"))
              (let ((eol-text (point)))
                (should (> eol-text bol-text))
                (should (not (memq (char-before eol-text) '(?\s ?\t))))))
            ;; 5. Native C-SPC + C-f + M-w selects & copies clean property-free text.
            (execute-kbd-macro (kbd "C-a"))
            (let ((start-pos (point)))
              (execute-kbd-macro (kbd "C-SPC"))
              (execute-kbd-macro (kbd "C-f C-f C-f C-f C-f C-f"))
              (should (region-active-p))
              (kill-ring-save (region-beginning) (region-end))
              (let ((copied (car kill-ring)))
                (should (equal copied "Cursor"))
                (should-not (text-properties-at 0 copied)))
              (deactivate-mark)
              (goto-char start-pos))
            ;; 6. Pressing C-n / <down> past viewport bottom auto-scrolls web-scroll.
            (let* ((rt (etaf-runtime-for-buffer buf))
                   (off0 (etaf-scroll-offset rt 'web-scroll))
                   (total-lines (count-lines (point-min) (point-max))))
              (dotimes (_ (+ total-lines 4))
                (execute-kbd-macro (kbd "C-n")))
              (let ((off1 (etaf-scroll-offset rt 'web-scroll)))
                (should (> off1 off0)))
              ;; M-< returns to top (offset 0); M-> jumps to bottom (> 0).
              (execute-kbd-macro (kbd "M-<"))
              (should (= (etaf-scroll-offset rt 'web-scroll) 0))
              (execute-kbd-macro (kbd "M->"))
              (should (> (etaf-scroll-offset rt 'web-scroll) 0))
              (execute-kbd-macro (kbd "M-<"))
              (should (= (etaf-scroll-offset rt 'web-scroll) 0)))
            ;; 7. `w' copies current page URL cleanly.
            (execute-kbd-macro (kbd "w"))
            (should (equal (car kill-ring) (concat base "/page1")))
            ;; 8. RET on plain heading text stays calmly on page1 without error.
            (execute-kbd-macro (kbd "M-<"))
            (execute-kbd-macro (kbd "RET"))
            (should (equal (plist-get (etaf-web-state buf) :url)
                           (concat base "/page1")))
            ;; 9. Moving cursor onto link and pressing RET navigates to /target.
            (let ((link-pos (save-excursion
                              (goto-char (point-min))
                              (search-forward "Target Destination")
                              (match-beginning 0))))
              (goto-char link-pos)
              (execute-kbd-macro (kbd "RET"))))
          (should (etaf-web-tests--wait-until
                   (lambda ()
                     (let ((st (etaf-web-state buf)))
                       (and (string-suffix-p "/target" (or (plist-get st :url) ""))
                            (eq (plist-get st :phase) 'ready)))))))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf (etaf-web-close)))
      (delete-directory cache t))))

(ert-deftest etaf-web-tests-heading-anchor-wrappers-and-hint-containers ()
  "Heading-wrapping `.header-anchor' links survive while decorative permalink icons are dropped.
VuePress/Theme-Plume `<h2 id=...><a class=\"header-anchor\" href=\"#...\"><span>Title</span></a></h2>'
headings compile to clean Markdown headings (unwrapping the self-link), while
icon-only/sr-only permalink markers (`#', `¶', `.sl-anchor-link') stay stripped,
and `.hint-container' callouts compile to `:::note' containers."
  (let* ((html
          (concat
           "<!doctype html><html><head><title>搭建私有 docker 镜像仓库</title></head>"
           "<body><main><div class=\"vp-doc plume-content\">"
           "<h1 class=\"page-title\">搭建私有 docker 镜像仓库</h1>"
           "<p>第一段正文说明搭建私有镜像仓库的背景与动机，提供充足的上下文内容。</p>"
           "<h2 id=\"客户端和服务端\" tabindex=\"-1\">"
           "<a class=\"header-anchor\" href=\"#客户端和服务端\"><span>客户端和服务端</span></a></h2>"
           "<p>当我们提到一个应用程序，同时还提到它的仓库，那么大概率是有客户端和服务端的区分。</p>"
           "<h3 id=\"sec-2\" tabindex=\"-1\">"
           "修改镜像存储目录"
           "<a class=\"header-anchor\" href=\"#sec-2\"><span class=\"sr-only\">Jump to heading</span><span aria-hidden=\"true\">#</span></a></h3>"
           "<h3 id=\"sec-3\">Starlight Section"
           "<a class=\"sl-anchor-link\" href=\"#sec-3\"><span aria-hidden=\"true\"><svg></svg></span><span class=\"sr-only\">Section titled Starlight Section</span></a></h3>"
           "<div class=\"hint-container note\">"
           "<p class=\"hint-container-title\">场景A：大型企业级应用</p>"
           "<p>推荐策略：设计令牌作为单一事实来源。</p></div>"
           "</div></main></body></html>"))
         (md (etaf-web-to-markdown html :base-url "https://example.com/blog/docker/")))
    (should (string-match-p "^## 客户端和服务端$" md))
    (should (string-match-p "^### 修改镜像存储目录$" md))
    (should (string-match-p "^### Starlight Section$" md))
    (should-not (string-match-p "Jump to heading" md))
    (should-not (string-match-p "Section titled" md))
    (should-not (string-match-p "\\[客户端和服务端\\]" md))
    (should (string-match-p "^:::note {title=\"场景A：大型企业级应用\"}$" md))
    (should (string-match-p "设计令牌作为单一事实来源" md))))

(provide 'etaf-web-tests)
;;; etaf-web-tests.el ends here
