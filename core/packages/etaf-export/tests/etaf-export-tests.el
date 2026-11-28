;;; etaf-export-tests.el --- Public API acceptance tests for etaf-export -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public API acceptance tests verifying `etaf-export' registration with
;; `etaf-ext', the live vector export preview workspace, vector SVG emission,
;; multi-page ISO A4 and single-page PDF generation via `rsvg-convert',
;; dark-to-light paper remapping, inline vector SVG/icon width and color
;; preservation, tab expansion and structured error handling.

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

(defun etaf-export-test--key-command (runtime key)
  "Send KEY through the command loop against RUNTIME's buffer."
  (let ((buf (etaf-runtime-buffer runtime)))
    (save-window-excursion
      (set-window-buffer (selected-window) buf)
      (with-current-buffer buf
        (let ((inhibit-message t))
          (execute-kbd-macro (kbd key)))))))

(ert-deftest etaf-export-registers-with-etaf-ext-and-exposes-minimal-commands ()
  (let* ((etaf-ext-storage-file nil)
         (etaf-ext-use-posframe nil)
         (orig-mode (bound-and-true-p etaf-ext-mode))
         (buf (generate-new-buffer " *etaf-export-reg-test*"))
         (rt nil))
    (unwind-protect
        (progn
          (etaf-export-register)
          (etaf-ext-mode 1)
          ;; Only the 3 core public commands are interactive.
          (should (commandp 'etaf-export))
          (should (commandp 'etaf-export-pdf))
          (should (commandp 'etaf-export-svg))
          (should-not (commandp 'etaf-export-doctor))
          (should-not (commandp 'etaf-export-register))
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
            (should (= (length dkeys) 3))
            (should (member "C-c C-e x x" dkeys))
            (should (member "C-c C-e x p" dkeys))
            (should (member "C-c C-e x s" dkeys)))
          ;; Opening the compact manager popup works cleanly in headless mode.
          (should (etaf-ext-open-popup 'etaf-export rt))
          (let ((ctx (etaf-ext-context 'etaf-export rt)))
            (should ctx)
            (etaf-ext-hide-popup ctx)))
      (etaf-ext-mode (if orig-mode 1 -1))
      (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest etaf-export-live-preview-workspace-navigates-and-updates-options ()
  (let* ((etaf-ext-storage-file nil)
         (etaf-ext-use-posframe nil)
         (orig-mode (bound-and-true-p etaf-ext-mode))
         (buf (generate-new-buffer " *etaf-export-preview-src*"))
         (rt nil)
         (pbuf nil)
         (sections
          (cl-loop for i from 1 to 26
                   collect
                   (etaf-node
                    'column '(:width (ch 68) :background-color "#212328"
                                     :padding ((lh 0) (ch 1)) :margin-bottom (lh 1))
                    (list
                     (etaf-node 'text '(:color "#4493f8" :font-weight bold)
                                (list (format "Preview Section %02d" i)))
                     (etaf-node 'text '(:color "#e6edf3")
                                (list (format "Body content for preview test %02d." i))))))))
    (unwind-protect
        (progn
          (etaf-export-register)
          (etaf-ext-mode 1)
          (etaf-mount
           buf
           (etaf-node 'column '(:width (ch 72) :background-color "#191a1c"
                                       :padding ((lh 1) (ch 2)))
                      sections)
           '(:viewport-width 640 :viewport-height 40
                             :meta (:app export-demo :kind document :title "Preview Source")))
          (setq rt (etaf-runtime-for-buffer buf))
          (setq pbuf (etaf-export rt))
          (should (buffer-live-p pbuf))
          (let ((prt (etaf-runtime-for-buffer pbuf)))
            (should (and prt (etaf-runtime-mounted-p prt)))
            ;; Preview buffer preserves user's mode-line and excludes itself from etaf-export matching.
            (with-current-buffer pbuf
              (should mode-line-format)
              (let ((txt (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "导出预览" txt))
                (should (string-match-p "1 / " txt))
                (should (string-match-p "A4" txt))))
            (should-not (etaf-ext-match-p 'etaf-export prt))
            ;; Drive interactive keys: next page, toggle theme, cycle page-mode to single, close.
            (etaf-export-test--key-command prt "n")
            (with-current-buffer pbuf
              (should (string-match-p "2 / " (buffer-substring-no-properties (point-min) (point-max)))))
            (etaf-export-test--key-command prt "p")
            (with-current-buffer pbuf
              (should (string-match-p "1 / " (buffer-substring-no-properties (point-min) (point-max)))))
            (etaf-export-test--key-command prt "t")
            (with-current-buffer pbuf
              (should (string-match-p "亮色打印" (buffer-substring-no-properties (point-min) (point-max)))))
            ;; Cycle page-mode A4 -> Letter -> single
            (etaf-export-test--key-command prt "m")
            (etaf-export-test--key-command prt "m")
            (with-current-buffer pbuf
              (should (string-match-p "1 / 1" (buffer-substring-no-properties (point-min) (point-max))))
              ;; Calling etaf-export-svg inside the preview buffer transparently targets source runtime.
              (let* ((tmp-svg (make-temp-file "etaf-export-inner-" nil ".svg"))
                     (res (etaf-export-svg tmp-svg :page-mode 'single)))
                (unwind-protect
                    (progn
                      (should (file-exists-p (plist-get res :file)))
                      (with-temp-buffer
                        (insert-file-contents (plist-get res :file))
                        (should (string-match-p "Preview Section 01" (buffer-string)))))
                  (ignore-errors (delete-file tmp-svg)))))
            (etaf-export-test--key-command prt "q")
            (should-not (buffer-live-p pbuf))))
      (etaf-ext-mode (if orig-mode 1 -1))
      (when (and pbuf (buffer-live-p pbuf))
        (ignore-errors (etaf-app-close pbuf)))
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

(ert-deftest etaf-export-aligns-unsliced-svg-icons-and-preserves-currentcolor-and-tabs ()
  (let* ((buf (generate-new-buffer " *etaf-export-icon-align*"))
         (tmp (make-temp-file "etaf-export-icon-" t))
         (rt nil)
         ;; Exact `etaf-ui-icon' descriptor shape: no :width/:height plist keys, no slice.
         (icon-svg "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><svg x='0' y='0.0' width='16' height='16' viewBox='0 0 14 14' fill='none' stroke='currentColor' stroke-width='1.4'><path d='M2 7L5 10L12 3'/></svg></svg>")
         (icon-img (list 'image :type 'svg :data icon-svg :ascent 'center :scale 1))
         (border-svg "<svg xmlns='http://www.w3.org/2000/svg' width='1' height='20'><rect width='1' height='20' fill='#cccccc'/></svg>")
         (border-img (list 'image :type 'svg :data border-svg :ascent 80)))
    (unwind-protect
        (cl-letf (((symbol-function 'etaf-display-metrics)
                   (lambda (&optional _rt) '(:char-width 8 :line-height 20 :ascent 80)))
                  ((symbol-function 'etaf-string-pixel-width)
                   (lambda (s) (* (string-width (substring-no-properties s)) 8))))
          (etaf-mount
           buf
           (etaf-node 'text nil '("placeholder"))
           '(:viewport-width 480 :viewport-height 20
                             :meta (:app export-demo :kind document :title "Icon Align")))
          (setq rt (etaf-runtime-for-buffer buf))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              ;; Row 0 (with 16px SVG icon): 1 + 16 + 16 + 72 + 136 + 1 = 242px
              (insert (propertize " " 'display (list '(slice 0 0 1 20) border-img))
                      (propertize " " 'display '(space :width (16)) 'face '(:background "#f3f4f6"))
                      (propertize "✓" 'display icon-img 'face '(:foreground "#1a7f37" :background "#f3f4f6"))
                      (propertize " 缓存命中" 'face '(:foreground "#1f2328" :background "#f3f4f6" :weight bold))
                      (propertize " " 'display '(space :width (136)) 'face '(:background "#f3f4f6"))
                      (propertize " " 'display (list '(slice 0 0 1 20) border-img))
                      "\n")
              ;; Row 1 (no icon): 1 + 16 + 80 + 144 + 1 = 242px
              (insert (propertize " " 'display (list '(slice 0 0 1 20) border-img))
                      (propertize " " 'display '(space :width (16)) 'face '(:background "#f3f4f6"))
                      (propertize "标题与摘要" 'face '(:foreground "#656d76" :background "#f3f4f6"))
                      (propertize " " 'display '(space :width (144)) 'face '(:background "#f3f4f6"))
                      (propertize " " 'display (list '(slice 0 0 1 20) border-img))
                      "\n")
              ;; Row 2 (contains a tab character that must expand to spaces in SVG)
              (insert "a\tb\n")))
          (let* ((svg-out (expand-file-name "align.svg" tmp))
                 (res (etaf-export-svg svg-out :runtime rt :page-mode 'single :theme 'current))
                 (svg-text (etaf-export-test--read-file (plist-get res :file)))
                 (right-border-xs nil)
                 (pos 0))
            ;; Every 1px right border slice (x > 200) must land at the exact same x coordinate.
            (while (string-match "<svg x=\"\\([0-9.]+\\)\" y=\"[0-9.]+\" width=\"1\\.00\" height=\"20\\.00\"" svg-text pos)
              (let ((xv (string-to-number (match-string 1 svg-text))))
                (when (> xv 200.0)
                  (push xv right-border-xs)))
              (setq pos (match-end 0)))
            (should (= (length right-border-xs) 2))
            (should (< (abs (- (nth 0 right-border-xs) (nth 1 right-border-xs))) 0.01))
            ;; Inline icon keeps true 16x16 width/height, centers vertically (y=2.00) and inherits green color.
            (should (string-match-p "y=\"2\\.00\" width=\"16\\.00\" height=\"16\\.00\"[^>]*color=\"#1a7f37\"" svg-text))
            ;; Literal tab was expanded to spaces before SVG emission.
            (should-not (string-search "\t" svg-text))
            (should (string-match-p ">a       b</text>" svg-text))))
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
                  "<text x=\"110\" y=\"42\" text-anchor=\"middle\" fill=\"white\" font-size=\"14\">Vector Diagram Label</text>"
                  "</svg>"))
         (img-desc (list 'image :type 'svg :data sample-svg :width 220 :height 72)))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-node 'column '(:width (ch 60) :background-color "#191a1c")
                      (list (etaf-node 'text '(:color "#e6edf3" :font-weight bold)
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
          ;; Light remapping also converts CSS named colors like fill="white" inside embedded SVGs.
          (let* ((light-out (expand-file-name "media-light.svg" tmp))
                 (res (etaf-export-svg light-out :runtime rt :page-mode 'single :theme 'light))
                 (svg-text (etaf-export-test--read-file (plist-get res :file))))
            (should-not (string-match-p "fill=\"white\"" svg-text)))
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
              ;; Text column stays <= 500px so A4 scale stays >= 0.80 (not ~0.44)
              (should (string-match "scale(\\([0-9.]+\\))" svg-text))
              (should (> (string-to-number (match-string 1 svg-text)) 0.80))))
          (when (plist-get (etaf-export-doctor) :ready)
            (let* ((pdf-out (expand-file-name "media.pdf" tmp))
                   (res (etaf-export-pdf pdf-out :runtime rt :page-mode 'single :theme 'current))
                   (txt (etaf-export-test--pdf-text pdf-out)))
              (should (etaf-export-test--pdf-header-p pdf-out))
              (should (= (plist-get res :pages) 1))
              (when txt
                (should (string-match-p "Vector Diagram Label" txt)))))
          ;; Large (>200 KB) embedded SVG must never overflow Emacs's regexp matcher stack
          ;; during SVG export or live preview composition.
          (let* ((rects (apply #'concat
                               (make-list 4000 "<rect x='1' y='1' width='4' height='4' fill='#2563eb'/>\n")))
                 (huge-svg (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"240\" height=\"72\" viewBox=\"0 0 240 72\">"
                                   rects "</svg>"))
                 (huge-desc (list 'image :type 'svg :data huge-svg :width 240 :height 72))
                 (huge-out (expand-file-name "huge.svg" tmp))
                 (pbuf nil))
            (should (> (length huge-svg) 200000))
            (unwind-protect
                (progn
                  (with-current-buffer buf
                    (let ((inhibit-read-only t))
                      (goto-char (point-max))
                      (dotimes (row 4)
                        (insert (propertize " " 'display (list (list 'slice 0 (* row 18) 240 18) huge-desc)))
                        (insert "\n"))))
                  (let ((res (etaf-export-svg huge-out :runtime rt :page-mode 'single :theme 'light)))
                    (should (= (plist-get res :pages) 1))
                    (should (> (file-attribute-size (file-attributes (plist-get res :file))) 200000)))
                  (setq pbuf (etaf-export rt))
                  (should (buffer-live-p pbuf)))
              (when (and pbuf (buffer-live-p pbuf))
                (ignore-errors (etaf-app-close pbuf))))))
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
           (etaf-export-svg nil :runtime rt)
           :type 'etaf-export-error)
          (should-error
           (etaf-export-svg "" :runtime rt)
           :type 'etaf-export-error)
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
