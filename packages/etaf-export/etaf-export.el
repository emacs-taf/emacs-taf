;;; etaf-export.el --- Zero-browser vector PDF & SVG export extension for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.3.10") (etaf-ui "0.3.6") (etaf-ext "0.1.0"))
;; Keywords: convenience, docs, extensions, ui
;; URL: https://github.com/emacs-taf/etaf-export

;;; Commentary:

;; Standalone zero-browser vector PDF and SVG export extension built strictly on
;; `etaf-ext''s public API.  Captures any mounted ETAF rendered page WYSIWYG —
;; preserving text, faces, backgrounds, borders, box-drawing tables, raster
;; images and inline vector Mermaid/MathJax SVGs — and exports multi-page ISO A4
;; or US Letter PDFs, continuous single-page PDFs, or standalone SVGs through
;; `rsvg-convert -f pdf'.  Supports optional perceptual dark-to-light paper
;; remapping without altering the live Emacs buffer.
;;
;; Public API
;;
;; Load this package with (require 'etaf-export) after adding this repository,
;; ETAF, ETAF UI, ETAF Ext, Ebox and ECSS roots to `load-path'.  Only the
;; interfaces listed below are supported for use by other packages; unlisted
;; symbols are internal even without a double hyphen.  docs/manual.md contains
;; workflows.
;;
;; Error: etaf-export-error
;; Raised when exporting fails due to missing runtime, missing `rsvg-convert',
;; invalid export options or output validation failure.
;;
;; Variable: etaf-export-default-page-mode
;; Default pagination mode symbol: `a4' (ISO A4), `letter' (US Letter) or
;; `single' (continuous single-page vector PDF).
;;
;; Variable: etaf-export-default-theme
;; Default export color mode: `current' (keep live page palette) or `light'
;; (remap dark pages onto white paper for printing).
;;
;; Variable: etaf-export-page-numbers
;; When non-nil, render subtle centered `N / M' footers on multi-page exports.
;;
;; Variable: etaf-export-margin
;; Default page margin in PDF points (1 pt = 1/72 inch).
;;
;; Variable: etaf-export-font-family
;; Optional SVG font-family override string; nil inherits the frame's default
;; font with CJK monospace fallbacks.
;;
;; Variable: etaf-export-rsvg-convert-program
;; Executable name or path for `rsvg-convert' used to generate vector PDFs.
;;
;; Function: etaf-export-register ()
;;;###autoload (autoload 'etaf-export-register "etaf-export" nil nil)
;; Register or re-register the `etaf-export' extension inside `etaf-ext'.
;;
;; Function: etaf-export-doctor ()
;;;###autoload (autoload 'etaf-export-doctor "etaf-export" nil nil)
;; Return capability report plist matching `etaf-install-doctor', verifying
;; whether `rsvg-convert' is available for PDF generation.
;;
;; Function: etaf-export-svg (output-file &key runtime (page-mode etaf-export-default-page-mode) (theme etaf-export-default-theme) (page-numbers etaf-export-page-numbers) (margin etaf-export-margin) (font-family etaf-export-font-family))
;;;###autoload (autoload 'etaf-export-svg "etaf-export" nil nil)
;; Export mounted RUNTIME (or the current buffer's runtime) as vector SVG
;; file(s) at OUTPUT-FILE and return a result plist with `:file', `:files',
;; `:format', `:pages', `:page-mode' and `:theme'.
;;
;; Function: etaf-export-pdf (output-file &key runtime (page-mode etaf-export-default-page-mode) (theme etaf-export-default-theme) (page-numbers etaf-export-page-numbers) (margin etaf-export-margin) (font-family etaf-export-font-family))
;;;###autoload (autoload 'etaf-export-pdf "etaf-export" nil nil)
;; Export mounted RUNTIME (or the current buffer's runtime) to a zero-browser
;; vector PDF at OUTPUT-FILE via `rsvg-convert -f pdf' and return a result plist
;; with `:file', `:format', `:pages', `:page-mode', `:theme' and `:bytes'.
;;
;; Function: etaf-export-current-pdf (&optional output-file page-mode theme runtime)
;;;###autoload (autoload 'etaf-export-current-pdf "etaf-export" nil t)
;; Interactive command exporting the active ETAF page to PDF, prompting for
;; OUTPUT-FILE when omitted.
;;
;; Function: etaf-export-popup (&optional runtime)
;;;###autoload (autoload 'etaf-export-popup "etaf-export" nil t)
;; Interactive command opening the floating export options popup for RUNTIME.

;;; Code:

;;;###autoload
(eval-and-compile
  (let* ((entry (or (and load-file-name
                         (not (string-suffix-p ".eln" load-file-name))
                         (file-directory-p
                          (expand-file-name "lisp" (file-name-directory load-file-name)))
                         load-file-name)
                    (bound-and-true-p byte-compile-current-file)
                    (locate-library "etaf-export")
                    buffer-file-name))
         (lisp-dir (and entry (expand-file-name "lisp" (file-name-directory entry)))))
    (when (and lisp-dir (file-directory-p lisp-dir))
      (add-to-list 'load-path lisp-dir))))

(require 'cl-lib)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)
(require 'etaf-export-snapshot)
(require 'etaf-export-svg)
(require 'etaf-export-pdf)
(require 'etaf-export-ui)

(defgroup etaf-export nil
  "Zero-browser vector PDF and SVG export extension for ETAF."
  :group 'etaf-ext
  :prefix "etaf-export-")

(defcustom etaf-export-default-page-mode 'a4
  "Default page layout mode when exporting an ETAF page."
  :type '(choice (const :tag "A4 paginated" a4)
                 (const :tag "US Letter paginated" letter)
                 (const :tag "Single continuous page" single))
  :group 'etaf-export)

(defcustom etaf-export-default-theme 'current
  "Default color theme strategy when exporting an ETAF page."
  :type '(choice (const :tag "Follow current page theme" current)
                 (const :tag "Force light print palette" light))
  :group 'etaf-export)

(defcustom etaf-export-page-numbers t
  "When non-nil, draw centered `N / M' footers on multi-page exports."
  :type 'boolean
  :group 'etaf-export)

(defcustom etaf-export-margin 28
  "Default page margin in PDF points (1 pt = 1/72 inch)."
  :type 'number
  :group 'etaf-export)

(defcustom etaf-export-font-family nil
  "Optional SVG font-family override string, or nil to inherit frame font."
  :type '(choice (const :tag "Inherit frame font" nil)
                 (string :tag "CSS font-family list"))
  :group 'etaf-export)

(defcustom etaf-export-rsvg-convert-program "rsvg-convert"
  "Program name or absolute path to `rsvg-convert'."
  :type 'string
  :group 'etaf-export)

(defun etaf-export--resolve-runtime (runtime)
  "Resolve mounted ETAF RUNTIME, signalling `etaf-export-error' if absent."
  (let ((rt (or runtime
                (etaf-current-runtime)
                (etaf-runtime-for-buffer (current-buffer)))))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-export-error (list "Current buffer is not a mounted ETAF page")))
    rt))

(defun etaf-export--validate-options (page-mode theme)
  "Validate PAGE-MODE and THEME symbols, signalling `etaf-export-error'."
  (unless (memq page-mode '(a4 letter single))
    (signal 'etaf-export-error (list "Invalid page-mode (expected a4, letter or single)" page-mode)))
  (unless (memq theme '(current light))
    (signal 'etaf-export-error (list "Invalid theme (expected current or light)" theme))))

;;;; Public API

;;;###autoload
(defun etaf-export-doctor ()
  "Return capability report plist verifying `rsvg-convert' availability."
  (etaf-export--doctor-report))

;;;###autoload
(cl-defun etaf-export-svg (output-file &key runtime
                                       (page-mode etaf-export-default-page-mode)
                                       (theme etaf-export-default-theme)
                                       (page-numbers etaf-export-page-numbers)
                                       (margin etaf-export-margin)
                                       (font-family etaf-export-font-family))
  "Export mounted RUNTIME as standalone vector SVG file(s) at OUTPUT-FILE."
  (unless (and (stringp output-file) (not (string-empty-p output-file)))
    (signal 'etaf-export-error (list "OUTPUT-FILE must be a non-empty file path")))
  (etaf-export--validate-options page-mode theme)
  (let* ((rt (etaf-export--resolve-runtime runtime))
         (snap (etaf-export--snapshot-runtime rt :theme theme :font-family font-family))
         (rendered (etaf-export--render-svg-pages snap
                                                  :page-mode page-mode
                                                  :margin margin
                                                  :page-numbers page-numbers))
         (svg-pages (plist-get rendered :svg-pages))
         (written (etaf-export--write-svg-files svg-pages output-file)))
    (list :file (car written)
          :files written
          :format 'svg
          :pages (length svg-pages)
          :page-mode page-mode
          :theme theme
          :lines (plist-get snap :line-count)
          :images (length (plist-get snap :images)))))

;;;###autoload
(cl-defun etaf-export-pdf (output-file &key runtime
                                       (page-mode etaf-export-default-page-mode)
                                       (theme etaf-export-default-theme)
                                       (page-numbers etaf-export-page-numbers)
                                       (margin etaf-export-margin)
                                       (font-family etaf-export-font-family))
  "Export mounted RUNTIME to a zero-browser vector PDF at OUTPUT-FILE."
  (unless (and (stringp output-file) (not (string-empty-p output-file)))
    (signal 'etaf-export-error (list "OUTPUT-FILE must be a non-empty file path")))
  (etaf-export--validate-options page-mode theme)
  (let* ((rt (etaf-export--resolve-runtime runtime))
         (snap (etaf-export--snapshot-runtime rt :theme theme :font-family font-family))
         (rendered (etaf-export--render-svg-pages snap
                                                  :page-mode page-mode
                                                  :margin margin
                                                  :page-numbers page-numbers))
         (svg-pages (plist-get rendered :svg-pages))
         (pdf-path (etaf-export--compile-pdf svg-pages output-file))
         (bytes (file-attribute-size (file-attributes pdf-path))))
    (list :file pdf-path
          :format 'pdf
          :pages (length svg-pages)
          :page-mode page-mode
          :theme theme
          :bytes bytes
          :lines (plist-get snap :line-count)
          :images (length (plist-get snap :images)))))

(defun etaf-export--interactive-export (ctx format page-mode theme)
  "Prompt for destination file and export CTX's Runtime in FORMAT."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (ext (if (eq format 'svg) "svg" "pdf"))
         (snap (etaf-export--snapshot-runtime rt :theme theme))
         (default-path (etaf-export--default-filename snap ext))
         (dest (read-file-name (format "导出 %s 到: " (upcase ext))
                               (file-name-directory default-path)
                               default-path nil
                               (file-name-nondirectory default-path)))
         (res (if (eq format 'svg)
                  (etaf-export-svg dest :runtime rt :page-mode page-mode :theme theme)
                (etaf-export-pdf dest :runtime rt :page-mode page-mode :theme theme))))
    (etaf-ext-notify ctx (format "已导出 %s（%d 页）" (upcase ext) (plist-get res :pages))
                     :detail (plist-get res :file))
    res))

(defun etaf-export--cmd-pdf (ctx)
  "Command exporting CTX's page as paginated PDF with current theme."
  (etaf-export--interactive-export ctx 'pdf etaf-export-default-page-mode etaf-export-default-theme))

(defun etaf-export--cmd-pdf-single (ctx)
  "Command exporting CTX's page as a continuous single-page PDF."
  (etaf-export--interactive-export ctx 'pdf 'single etaf-export-default-theme))

(defun etaf-export--cmd-pdf-light (ctx)
  "Command exporting CTX's page as a light-theme print-ready A4 PDF."
  (etaf-export--interactive-export ctx 'pdf 'a4 'light))

(defun etaf-export--cmd-svg (ctx)
  "Command exporting CTX's page as standalone vector SVG."
  (etaf-export--interactive-export ctx 'svg etaf-export-default-page-mode etaf-export-default-theme))

(defun etaf-export--cmd-panel (ctx)
  "Command opening the floating export options panel on CTX."
  (etaf-ext-show-popup ctx (etaf-export--popup-view ctx)
                       :title "导出页面为 PDF / SVG" :width 56 :height 17))

;;;###autoload
(defun etaf-export-current-pdf (&optional output-file page-mode theme runtime)
  "Export the current mounted ETAF page to PDF."
  (interactive)
  (let* ((rt (etaf-export--resolve-runtime runtime))
         (pm (or page-mode etaf-export-default-page-mode))
         (th (or theme etaf-export-default-theme))
         (dest (or output-file
                   (let* ((snap (etaf-export--snapshot-runtime rt :theme th))
                          (def (etaf-export--default-filename snap "pdf")))
                     (read-file-name "导出 PDF 到: "
                                     (file-name-directory def)
                                     def nil
                                     (file-name-nondirectory def)))))
         (res (etaf-export-pdf dest :runtime rt :page-mode pm :theme th)))
    (when (called-interactively-p 'interactive)
      (message "已导出 PDF（%d 页）: %s" (plist-get res :pages) (plist-get res :file)))
    res))

;;;###autoload
(defun etaf-export-popup (&optional runtime)
  "Open the floating export options popup for RUNTIME."
  (interactive)
  (etaf-ext-run-command 'etaf-export 'panel runtime))

;;;###autoload
(defun etaf-export-register ()
  "Register the standalone `etaf-export' extension inside `etaf-ext'."
  (etaf-ext-define etaf-export
    :name "页面导出 PDF / SVG"
    :version "0.1.0"
    :icon "导"
    :tone 'info
    :prefix-hint "x"
    :description "将任意已挂载 ETAF 渲染页面零浏览器导出为真矢量 PDF 或 SVG，支持 A4 分页、单页长图与强制亮色打印。"
    :activation 'on-command
    :matches (list :apps t
                   :predicate (lambda (_rt meta _buf)
                                (not (eq (plist-get meta :app) 'etaf-ext-manager))))
    :priority 70
    :debounce 0.1
    :permissions '(keys popup notify)
    :commands '((export-pdf   :subkey "p" :label "导出当前页面为 PDF（A4 分页）" :fn etaf-export--cmd-pdf)
                (export-long  :subkey "l" :label "导出当前页面为单页长 PDF"     :fn etaf-export--cmd-pdf-single)
                (export-light :subkey "L" :label "强制亮色导出打印版 A4 PDF"     :fn etaf-export--cmd-pdf-light)
                (export-svg   :subkey "s" :label "导出当前页面为矢量 SVG"        :fn etaf-export--cmd-svg)
                (panel        :subkey "x" :label "打开导出设置面板"              :fn etaf-export--cmd-panel))
    :popup #'etaf-export--popup-view))

(etaf-export-register)

(provide 'etaf-export)
;;; etaf-export.el ends here
