;;; etaf-export-tests.el --- Public API acceptance tests for etaf-export -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public API acceptance tests verifying `etaf-export' registration with
;; `etaf-ext', vector SVG emission, multi-page ISO A4 and single-page PDF
;; generation via `rsvg-convert', dark-to-light paper remapping, inline vector
;; SVG preservation and error handling.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-export)

(defun etaf-export-test--read-file (path)
  "Read UTF-8 text from PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun etaf-export-test--pdf-header-p (path)
  "Return non-nil when PATH begins with a `%PDF-' header."
  (and (file-exists-p path)
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (insert-file-contents-literally path nil 0 8)
         (string-prefix-p "%PDF-" (buffer-string)))))

(defun etaf-export-test--pdf-page-count (path)
  "Return page count of PDF at PATH via `pdfinfo', or nil when unavailable."
  (when-let* ((bin (executable-find "pdfinfo")))
    (with-temp-buffer
      (when (eql 0 (call-process bin nil t nil path))
        (goto-char (point-min))
        (when (re-search-forward "^Pages:[ \t]+\\([0-9]+\\)" nil t)
          (string-to-number (match-string 1)))))))

(defun etaf-export-test--pdf-text (path)
  "Extract selectable text from PDF at PATH via `pdftotext', or nil."
  (when-let* ((bin (executable-find "pdftotext")))
    (with-temp-buffer
      (when (eql 0 (call-process bin nil t nil path "-"))
        (buffer-string)))))

(ert-deftest etaf-export-registers-with-etaf-ext-and-exposes-key-layer ()
  (let* ((etaf-ext-storage-file nil)
         (etaf-ext-use-posframe nil)
         (orig-mode (bound-and-true-p etaf-ext-mode))
         (buf (generate-new-buffer " *etaf-export-reg-test*"))
         (rt nil))
    (unwind-protect
        (progn
          (etaf-export-register)
          (etaf-ext-mode 1)
          (let ((info (etaf-ext-info 'etaf-export)))
            (should info)
            (should (equal (plist-get info :icon) "导"))
            (should (eq (plist-get info :tone) 'info))
            (should (equal (plist-get info :prefix-hint) "x")))
          (let ((doc (etaf-export-doctor)))
            (should (eq (plist-get doc :package) 'etaf-export))
            (should (listp (plist-get doc :required))))
          (etaf-mount
           buf
           (etaf-node 'column '(:width (ch 50))
                      (list (etaf-node 'text '(:font-weight bold) '("Export Test Page"))))
           '(:viewport-width 480 :viewport-height 20
                             :meta (:app export-demo :kind document :title "Export Demo")))
          (setq rt (etaf-runtime-for-buffer buf))
          (let* ((hdata (etaf-help-data rt))
                 (ext-group (cl-find 'extension (plist-get hdata :groups)
                                     :key (lambda (g) (plist-get g :kind))))
                 (keys (and ext-group
                            (mapcar (lambda (e) (plist-get e :key))
                                    (plist-get ext-group :entries))))
                 (bindings (etaf-ext-command-bindings rt 'etaf-export))
                 (dkeys (mapcar (lambda (r) (plist-get r :dispatch-key)) bindings)))
            (should ext-group)
            ;; Unified extension prefix is installed without claiming C-c <letter>.
            (should (member "C-c C-e" keys))
            (should-not (cl-some (lambda (k) (string-prefix-p "C-c x" k)) keys))
            (should (member "C-c C-e x p" dkeys))
            (should (member "C-c C-e x l" dkeys))
            (should (member "C-c C-e x L" dkeys))
            (should (member "C-c C-e x s" dkeys))
            (should (member "C-c C-e x x" dkeys)))
          ;; Opening popup works cleanly in headless batch mode
          (should (etaf-export-popup rt))
          (let ((ctx (etaf-ext-context 'etaf-export rt)))
            (should ctx)
            (etaf-ext-hide-popup ctx)))
      (etaf-ext-mode (if orig-mode 1 -1))
      (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-export-svg-and-pdf-paginated-a4-single-and-light-remap ()
  (let* ((etaf-ext-storage-file nil)
         (etaf-ext-use-posframe nil)
         (buf (generate-new-buffer " *etaf-export-doc-test*"))
         (tmp (make-temp-file "etaf-export-test-" t))
         (rt nil)
         (sections
          (cl-loop for i from 1 to 28
                   collect
                   (etaf-node
                    'column '(:width (ch 72) :background-color "#212328"
                                     :border ((px 1) solid "#303338")
                                     :padding ((lh 0) (ch 1))
                                     :margin-bottom (lh 1))
                    (list
                     (etaf-node 'text '(:color "#4493f8" :font-weight bold)
                                (list (format "Section %02d — 章节测试" i)))
                     (etaf-node 'text '(:color "#e6edf3")
                                (list (format "Rendered ETAF body line %02d with 中文混排 text." i))))))))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-node 'column '(:width (ch 76) :background-color "#191a1c"
                                       :padding ((lh 1) (ch 2)))
                      (cons (etaf-node 'text '(:color "#e6edf3" :font-weight bold)
                                       '("ETAF Export Multi-Page Document"))
                            sections))
           '(:viewport-width 640 :viewport-height 40
                             :meta (:app export-demo :kind document :title "Multi Page")))
          (setq rt (etaf-runtime-for-buffer buf))
          ;; 1. Multi-page A4 SVG export in current dark theme
          (let* ((svg-out (expand-file-name "dark.svg" tmp))
                 (res (etaf-export-svg svg-out :runtime rt :page-mode 'a4 :theme 'current))
                 (pages (plist-get res :pages))
                 (first-svg (etaf-export-test--read-file (plist-get res :file))))
            (should (> pages 1))
            (should (= (length (plist-get res :files)) pages))
            (should (string-match-p "width=\"595\\.28pt\" height=\"841\\.89pt\"" first-svg))
            (should (string-match-p "fill=\"#191a1c\"" first-svg))
            (should (string-match-p "ETAF Export Multi-Page Document" first-svg))
            (should (string-match-p "1 / " first-svg)))
          ;; 2. Light-theme paper remap must turn dark canvas into #ffffff without mutating buffer
          (let* ((light-svg-out (expand-file-name "light.svg" tmp))
                 (res (etaf-export-svg light-svg-out :runtime rt :page-mode 'a4 :theme 'light))
                 (svg-text (etaf-export-test--read-file (plist-get res :file)))
                 (live-remap (with-current-buffer buf face-remapping-alist)))
            (should (string-match-p "fill=\"#ffffff\"" svg-text))
            (should-not (string-match-p "fill=\"#191a1c\"" svg-text))
            (should (string-match-p "#191a1c" (format "%S" live-remap))))
          ;; 3. Single-page continuous SVG produces strictly 1 page
          (let* ((single-svg (expand-file-name "single.svg" tmp))
                 (res (etaf-export-svg single-svg :runtime rt :page-mode 'single :theme 'current)))
            (should (= (plist-get res :pages) 1))
            (should (file-exists-p single-svg)))
          ;; 4. Real PDF generation via rsvg-convert when installed
          (when (plist-get (etaf-export-doctor) :ready)
            (let* ((pdf-a4 (expand-file-name "doc-a4.pdf" tmp))
                   (res-a4 (etaf-export-pdf pdf-a4 :runtime rt :page-mode 'a4 :theme 'current))
                   (pdf-single (expand-file-name "doc-single.pdf" tmp))
                   (res-single (etaf-export-pdf pdf-single :runtime rt :page-mode 'single :theme 'light))
                   (a4-pages (plist-get res-a4 :pages))
                   (a4-info-pages (etaf-export-test--pdf-page-count pdf-a4))
                   (single-info-pages (etaf-export-test--pdf-page-count pdf-single))
                   (extracted (etaf-export-test--pdf-text pdf-a4)))
              (should (etaf-export-test--pdf-header-p pdf-a4))
              (should (> a4-pages 1))
              (when a4-info-pages
                (should (= a4-info-pages a4-pages)))
              (should (etaf-export-test--pdf-header-p pdf-single))
              (should (= (plist-get res-single :pages) 1))
              (when single-info-pages
                (should (= single-info-pages 1)))
              (when extracted
                (should (string-match-p "ETAF Export Multi-Page Document" extracted))
                (should (string-match-p "章节测试" extracted))))))
      (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest etaf-export-embeds-vector-svg-with-scoped-ids-and-raster-images ()
  (let* ((buf (generate-new-buffer " *etaf-export-svg-embed*"))
         (tmp (make-temp-file "etaf-export-media-" t))
         (rt nil)
         (sample-svg
          (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"220\" height=\"72\" viewBox=\"0 0 220 72\">"
                  "<defs><linearGradient id=\"g1\"><stop offset=\"0%\" stop-color=\"#3b82f6\"/>"
                  "<stop offset=\"100%\" stop-color=\"#1d4ed8\"/></linearGradient></defs>"
                  "<rect x=\"2\" y=\"2\" width=\"216\" height=\"68\" rx=\"8\" fill=\"url(#g1)\"/>"
                  "<text x=\"110\" y=\"42\" text-anchor=\"middle\" fill=\"#ffffff\" font-size=\"14\">Vector Diagram Label</text>"
                  "</svg>"))
         (img-desc (list 'image :type 'svg :data sample-svg :width 220 :height 72)))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-node 'column '(:width (ch 60) :background-color "#ffffff")
                      (list (etaf-node 'text '(:color "#1f2328" :font-weight bold)
                                       '("Embedded Vector SVG Test"))))
           '(:viewport-width 480 :viewport-height 20
                             :meta (:app export-demo :kind document :title "Vector SVG")))
          (setq rt (etaf-runtime-for-buffer buf))
          ;; Append a multi-row sliced vector SVG directly in the buffer matching Ebox slice shape
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (goto-char (point-max))
              (insert "\n")
              (dotimes (row 4)
                (insert (propertize " " 'display (list (list 'slice 0 (* row 18) 220 18) img-desc)))
                (insert "\n"))))
          (let* ((svg-out (expand-file-name "media.svg" tmp))
                 (res (etaf-export-svg svg-out :runtime rt :page-mode 'single :theme 'current))
                 (svg-text (etaf-export-test--read-file (plist-get res :file))))
            (should (= (plist-get res :images) 1))
            ;; Inner SVG embedded as nested <svg> with scoped id (not rasterized <image>)
            (should (string-match-p "id=\"p1_m1_g1\"" svg-text))
            (should (string-match-p "url(#p1_m1_g1)" svg-text))
            (should (string-match-p "Vector Diagram Label" svg-text)))
          ;; An overflowing 1200px diagram must clamp inside the text column instead
          ;; of shrinking the entire A4 document's typography.
          (let* ((wide-svg
                  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"72\" viewBox=\"0 0 1200 72\"><rect width=\"1200\" height=\"72\" fill=\"#2563eb\"/></svg>")
                 (wide-desc (list 'image :type 'svg :data wide-svg :width 1200 :height 72)))
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (dotimes (row 4)
                  (insert (propertize " " 'display (list (list 'slice 0 (* row 18) 1200 18) wide-desc)))
                  (insert "\n"))))
            (let* ((a4-svg (expand-file-name "wide-a4.svg" tmp))
                   (res (etaf-export-svg a4-svg :runtime rt :page-mode 'a4 :theme 'current))
                   (svg-text (etaf-export-test--read-file (car (plist-get res :files)))))
              (should (= (plist-get res :images) 2))
              ;; Text column stays <= 500px so A4 scale stays >= 0.85 (not ~0.44)
              (should (string-match "scale(\\([0-9.]+\\))" svg-text))
              (should (> (string-to-number (match-string 1 svg-text)) 0.80))))
          (when (plist-get (etaf-export-doctor) :ready)
            (let* ((pdf-out (expand-file-name "media.pdf" tmp))
                   (res (etaf-export-pdf pdf-out :runtime rt :page-mode 'single :theme 'current))
                   (txt (etaf-export-test--pdf-text pdf-out)))
              (should (etaf-export-test--pdf-header-p pdf-out))
              (should (= (plist-get res :pages) 1))
              (when txt
                (should (string-match-p "Vector Diagram Label" txt))))))
      (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf))
      (ignore-errors (delete-directory tmp t)))))

(ert-deftest etaf-export-signals-structured-errors-for-invalid-inputs ()
  (let* ((buf (generate-new-buffer " *etaf-export-err-test*"))
         (plain (generate-new-buffer " *etaf-export-plain*"))
         (tmp (make-temp-file "etaf-export-err-" t))
         (rt nil))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-node 'text nil '("Error test"))
           '(:viewport-width 320 :viewport-height 10 :meta (:app export-demo)))
          (setq rt (etaf-runtime-for-buffer buf))
          (should-error
           (etaf-export-svg (expand-file-name "x.svg" tmp) :runtime rt :page-mode 'bogus)
           :type 'etaf-export-error)
          (should-error
           (etaf-export-svg (expand-file-name "x.svg" tmp) :runtime rt :theme 'neon)
           :type 'etaf-export-error)
          (with-current-buffer plain
            (should-error
             (etaf-export-svg (expand-file-name "x.svg" tmp))
             :type 'etaf-export-error))
          (let ((etaf-export-rsvg-convert-program "/nonexistent/rsvg-convert-missing"))
            (should-error
             (etaf-export-pdf (expand-file-name "x.pdf" tmp) :runtime rt)
             :type 'etaf-export-error)))
      (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p plain) (kill-buffer plain))
      (ignore-errors (delete-directory tmp t)))))

(provide 'etaf-export-tests)
;;; etaf-export-tests.el ends here
