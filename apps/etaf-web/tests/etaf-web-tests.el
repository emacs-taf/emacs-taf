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
              (let* ((chrome-before (with-current-buffer buf
                                      (buffer-substring-no-properties
                                       (point-min) (line-end-position))))
                     (before (etaf-scroll-offset (etaf-runtime-for-buffer buf) 'web-scroll)))
                (execute-kbd-macro (kbd "C-v"))
                (should (> (etaf-scroll-offset (etaf-runtime-for-buffer buf) 'web-scroll)
                           before))
                (should (equal (with-current-buffer buf
                                 (buffer-substring-no-properties
                                  (point-min) (line-end-position)))
                               chrome-before))))))
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

(provide 'etaf-web-tests)
;;; etaf-web-tests.el ends here
