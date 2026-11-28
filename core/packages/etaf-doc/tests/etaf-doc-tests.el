;;; -*- lexical-binding: t; -*-
;;; etaf-doc-tests.el --- Acceptance tests for etaf-doc shared infrastructure

(require 'ert)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-doc)

(defconst etaf-doc-test--palette
  '((:bg . "#ffffff")
    (:ink . "#1f2328")
    (:muted . "#59636e")
    (:faint . "#8c959f")
    (:panel . "#f6f8fa")
    (:panel2 . "#eaeef2")
    (:border . "#d1d9e0")
    (:accent . "#0969da")
    (:accent-soft . "#ddf4ff")
    (:ok . "#1a7f37")
    (:ok-soft . "#dafbe1")
    (:warn . "#9a6700")
    (:warn-soft . "#fff8c5")
    (:danger . "#cf222e")
    (:danger-soft . "#ffebe9")
    (:important . "#8250df")
    (:important-soft . "#fbefff"))
  "Representative palette used by `etaf-doc' tests.")

(ert-deftest etaf-doc-cache-urls-and-lru-warming ()
  "URL classification, disk warming and QR cache paths stay pure and deterministic."
  (should (etaf-doc-cache-http-url-p "https://example.com/a.png"))
  (should (etaf-doc-cache-image-url-p "https://example.com/a.webp?v=2"))
  (should-not (etaf-doc-cache-http-url-p "file:///tmp/a.png"))
  (should-not (etaf-doc-cache-image-url-p "https://example.com/page.html"))
  (let* ((dir (make-temp-file "etaf-doc-cache-test-" t))
         (url "https://example.invalid/unit-test-asset.png")
         (cached (expand-file-name (concat (secure-hash 'sha1 url) ".png") dir)))
    (unwind-protect
        (progn
          (with-temp-file cached (insert "PNGDATA"))
          (should (etaf-doc-cache-warm-urls (list url) dir))
          (should (equal (etaf-doc-cache-image-path url) cached))
          (let ((qr (etaf-doc-qrcode-file "https://etaf.top" dir)))
            (should (string-suffix-p ".png" qr))
            (should (equal qr (etaf-doc-qrcode-file "https://etaf.top" dir)))))
      (delete-directory dir t))))

(ert-deftest etaf-doc-typeset-options-and-header-dimensions ()
  "Typeset JSON options and SVG/PNG header inspection run without rasterization."
  (let* ((palette '(:page "#ffffff" :ink "#1f2328" :muted "#59636e"
                    :border "#d1d9e0" :panel "#f6f8fa" :panel2 "#eaeef2"
                    :accent "#0969da" :ok "#1a7f37" :warn "#9a6700"
                    :important "#8250df" :danger "#cf222e"))
         (m-json (etaf-doc-typeset-options-json 'mermaid palette '(:font-size 16 :scale 2)))
         (t-json (etaf-doc-typeset-options-json 'math palette '(:pixels 16 :cell-height 20)))
         (dir (make-temp-file "etaf-doc-svg-test-" t))
         (svg (expand-file-name "sample.svg" dir)))
    (unwind-protect
        (progn
          (should (string-match-p "\"--pele-accent\":\"#0969da\"" m-json))
          (should (string-match-p "\"ink\":\"#1f2328\"" t-json))
          (with-temp-file svg
            (insert "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 320 160\"></svg>"))
          (should (equal (etaf-doc-typeset-image-pixels svg) '(320 . 160)))
          (let ((grid (etaf-doc-typeset-grid-for-pixels '(320 . 160) 60 20 '(8 . 16))))
            (should (equal grid '(40 . 10)))))
      (delete-directory dir t))))

(ert-deftest etaf-doc-assets-sandbox-slicing-symbol-and-tree ()
  "Workspace path confinement blocks escapes while slicing, symbol and tree reads succeed."
  (let* ((dir (make-temp-file "etaf-doc-assets-test-" t))
         (sample (expand-file-name "sample.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file sample
            (insert ";; header\n(defun sample-fn (x)\n  (+ x 1))\n;; footer\n"))
          (should (equal (etaf-doc-assets-lang-for-path sample) "elisp"))
          (should (etaf-doc-assets-safe-path dir "sample.el"))
          (should-not (etaf-doc-assets-safe-path dir "../../etc/passwd"))
          (let ((slice (etaf-doc-assets-read-slice dir "sample.el" '(:symbol "sample-fn"))))
            (should (plist-get slice :ok))
            (should (= (plist-get slice :start-line) 2))
            (should (= (plist-get slice :end-line) 3))
            (should (string-match-p "defun sample-fn" (plist-get slice :content))))
          (let ((sym (etaf-doc-assets-inspect-symbol "etaf-doc-assets-safe-path" dir)))
            (should (plist-get sym :ok))
            (should (equal (plist-get sym :kind) "函数")))
          (let ((tree (etaf-doc-assets-project-tree dir "." '(:depth 2))))
            (should (plist-get tree :ok))
            (should (cl-some (lambda (it) (equal (plist-get it :name) "sample.el"))
                             (plist-get tree :items)))))
      (delete-directory dir t))))

(ert-deftest etaf-doc-protocol-conversion-validation-and-registry ()
  "Protocol converts types, validates bounds/tokens, and manages extends/replace/undefine."
  (should (equal (etaf-doc-protocol-convert 'length "12ch") '(ch 12)))
  (should (eq (etaf-doc-protocol-convert 'boolean "false") nil))
  (should (eq (etaf-doc-protocol-convert 'accent "Primary") 'primary))
  (should (etaf-doc-protocol-validate-value :color '(:type color) "#ff0000" 'document))
  (should-not (etaf-doc-protocol-validate-value :color '(:type color) "primary" 'document))
  (should (etaf-doc-protocol-validate-value :n '(:type number :min 1 :max 5 :integer t) 6 'document))
  (let ((reg (make-hash-table :test #'eq))
        (styles '(((card) (:accent primary)))))
    (etaf-doc-protocol-define-node
     reg 'card '(:name "card" :attrs ((title :type string :default "A")) :view identity)
     1 'error t)
    (should (gethash 'card reg))
    (etaf-doc-protocol-define-node
     reg 'card '(:extends t :attrs ((note :type string)))
     1 'error)
    (should (= (length (plist-get (gethash 'card reg) :attrs)) 2))
    (setq styles (etaf-doc-protocol-undefine-node reg styles 'card))
    (should (= (length (plist-get (gethash 'card reg) :attrs)) 1))
    (etaf-doc-protocol-define-node reg 'custom-box '(:attrs ((x :type number))) 1 'error)
    (setq styles (cons '((custom-box) (:x 1)) styles))
    (setq styles (etaf-doc-protocol-undefine-node reg styles 'custom-box))
    (should-not (gethash 'custom-box reg))
    (should (= (length styles) 1))))

(ert-deftest etaf-doc-widgets-mount-and-obey-hover-discipline ()
  "Editorial widgets mount cleanly and suppress hover on selected leaf buttons."
  (let ((buf (generate-new-buffer " *etaf-doc-widgets*"))
        (pressed 0))
    (unwind-protect
        (progn
          (etaf-mount
           buf
           (etaf-view
            (column :width '(ch 76) :item-gap '(lh 1)
              (expr (etaf-doc-widget-leaf-button
                     etaf-doc-test--palette "Active" (lambda () (cl-incf pressed))
                     :selected t :ref 'active-leaf))
              (expr (etaf-doc-widget-leaf-button
                     etaf-doc-test--palette "Idle" (lambda () (cl-incf pressed))
                     :ref 'idle-leaf))
              (expr (etaf-doc-widget-pill
                     etaf-doc-test--palette "Tab 1" nil (lambda () (cl-incf pressed)) "hint" t))
              (expr (etaf-doc-widget-status-badge etaf-doc-test--palette "READY" 'success))
              (expr (etaf-doc-widget-notice etaf-doc-test--palette "Something failed" 'danger))
              (expr (etaf-doc-widget-progress-bars
                     etaf-doc-test--palette '(("Build" 80 100 80 "80%")) 72 '(:title "Status")))
              (expr (etaf-doc-widget-line-chart
                     etaf-doc-test--palette '(("A" . 10) ("B" . 25) ("C" . 18)) 64
                     '(:label "Trend" :height 4)))
              (expr (etaf-doc-widget-source-card
                     etaf-doc-test--palette "demo.el" "L1-2"
                     (etaf-node 'text nil '("(+ 1 2)")))))))
          (let ((rt (etaf-runtime-for-buffer buf))
                (text (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Build" text))
            (should (string-match-p "Trend" text))
            (should (string-match-p "demo.el" text))
            (should-not (plist-get (etaf-runtime-host-props-for rt 'active-leaf) :hover-style))
            (should (plist-get (etaf-runtime-host-props-for rt 'idle-leaf) :hover-style))))
      (when-let* ((rt (etaf-runtime-for-buffer buf))) (etaf-unmount rt))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'etaf-doc-tests)
;;; etaf-doc-tests.el ends here
