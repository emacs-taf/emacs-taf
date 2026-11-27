;;; etaf-export.el --- Zero-browser vector PDF & SVG export extension for ETAF -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.2.3
;; Package-Requires: ((emacs "29.1") (etaf "0.3.10") (etaf-ui "0.3.6") (etaf-ext "0.1.0"))
;; Keywords: convenience, docs, extensions, ui
;; URL: https://github.com/emacs-taf/etaf-export

;;; Commentary:

;; Standalone zero-browser vector PDF and SVG export extension built strictly on
;; `etaf-ext''s public API.  Captures any mounted ETAF rendered page WYSIWYG —
;; preserving text, faces, backgrounds, borders, box-drawing tables, inline
;; icons, raster images and inline vector Mermaid/MathJax SVGs — and exports
;; multi-page ISO A4 or US Letter PDFs, continuous single-page PDFs, or
;; standalone SVGs through `rsvg-convert -f pdf'.  Provides a live zero-browser
;; vector print-preview workspace (`etaf-export') and optional perceptual
;; dark-to-light paper remapping without altering the live Emacs buffer.
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
;; Latin and CJK fonts with monospace fallbacks.
;;
;; Variable: etaf-export-rsvg-convert-program
;; Executable name or path for `rsvg-convert' used to generate vector PDFs.
;;
;; Function: etaf-export (&optional runtime)
;;;###autoload (autoload 'etaf-export "etaf-export" nil t)
;; Interactive command opening the live vector Export Preview workspace for
;; mounted RUNTIME (defaulting to the current buffer's ETAF Runtime).
;;
;; Function: etaf-export-pdf (&optional output-file &key runtime (page-mode etaf-export-default-page-mode) (theme etaf-export-default-theme) (page-numbers etaf-export-page-numbers) (margin etaf-export-margin) (font-family etaf-export-font-family))
;;;###autoload (autoload 'etaf-export-pdf "etaf-export" nil t)
;; Export mounted RUNTIME (or the current buffer's runtime) to a zero-browser
;; vector PDF at OUTPUT-FILE via `rsvg-convert -f pdf' and return a result plist
;; with `:file', `:format', `:pages', `:page-mode', `:theme', `:bytes',
;; `:lines' and `:images'.  When called interactively (or with nil OUTPUT-FILE
;; on an interactive Emacs session), prompts for the output path and notifies
;; on completion; callers may wrap it with custom keyword arguments to define
;; personal presets.
;;
;; Function: etaf-export-svg (&optional output-file &key runtime (page-mode etaf-export-default-page-mode) (theme etaf-export-default-theme) (page-numbers etaf-export-page-numbers) (margin etaf-export-margin) (font-family etaf-export-font-family))
;;;###autoload (autoload 'etaf-export-svg "etaf-export" nil t)
;; Export mounted RUNTIME (or the current buffer's runtime) as vector SVG
;; file(s) at OUTPUT-FILE and return a result plist with `:file', `:files',
;; `:format', `:pages', `:page-mode', `:theme', `:lines' and `:images'.  When
;; called interactively (or with nil OUTPUT-FILE on an interactive session),
;; prompts for the output path and notifies on completion.
;;
;; Function: etaf-export-register ()
;;;###autoload (autoload 'etaf-export-register "etaf-export" nil nil)
;; Register or re-register the `etaf-export' extension inside `etaf-ext'.
;;
;; Function: etaf-export-doctor ()
;;;###autoload (autoload 'etaf-export-doctor "etaf-export" nil nil)
;; Return capability report plist matching `etaf-install-doctor', verifying
;; whether `rsvg-convert' is available for PDF generation.

;;; Code:

;;;###autoload
(eval-and-compile
  (let ((lisp-dir
         (catch 'found
           (dolist (file (list (bound-and-true-p byte-compile-current-file)
                               (and load-file-name
                                    (not (string-suffix-p ".eln" load-file-name))
                                    load-file-name)
                               (locate-library "etaf-export")
                               buffer-file-name))
             (when (stringp file)
               (let* ((dir (file-name-directory file))
                      (sub (and dir (expand-file-name "lisp" dir))))
                 (when (and sub
                            (file-directory-p sub)
                            (or (file-exists-p (expand-file-name "etaf-export.el" dir))
                                (file-exists-p (expand-file-name "etaf-export.elc" dir))))
                   (throw 'found sub))))))))
    (when lisp-dir
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
  "Resolve mounted ETAF RUNTIME, signalling `etaf-export-error' if absent.
When invoked inside the `*ETAF Export Preview*' workspace, transparently target
its underlying source runtime."
  (let ((rt (or runtime
                (etaf-current-runtime)
                (etaf-runtime-for-buffer (current-buffer)))))
    (when (and rt (etaf-runtime-mounted-p rt)
               (eq (plist-get (etaf-runtime-meta rt) :app) 'etaf-export-preview))
      (let* ((st (etaf-app-state (etaf-runtime-buffer rt)))
             (src (and (listp st) (plist-get st :source-rt))))
        (setq rt src)))
    (unless (and rt (etaf-runtime-mounted-p rt))
      (signal 'etaf-export-error (list "Current buffer is not a mounted ETAF page")))
    rt))

(defun etaf-export--validate-options (page-mode theme)
  "Validate PAGE-MODE and THEME symbols, signalling `etaf-export-error'."
  (unless (memq page-mode '(a4 letter single))
    (signal 'etaf-export-error (list "Invalid page-mode (expected a4, letter or single)" page-mode)))
  (unless (memq theme '(current light))
    (signal 'etaf-export-error (list "Invalid theme (expected current or light)" theme))))

(defun etaf-export--resolve-output-file (output-file runtime ext)
  "Return validated output path from OUTPUT-FILE, prompting interactively if nil."
  (cond
   ((and (null output-file) (not noninteractive))
    (etaf-export--prompt-output-path runtime ext))
   ((and (stringp output-file) (not (string-empty-p output-file)))
    output-file)
   (t
    (signal 'etaf-export-error (list "OUTPUT-FILE must be a non-empty file path")))))

;;;; Public API

;;;###autoload
(defun etaf-export-doctor ()
  "Return capability report plist verifying `rsvg-convert' availability."
  (etaf-export--doctor-report))

;;;###autoload
(defun etaf-export (&optional runtime)
  "Open the live vector Export Preview workspace for mounted RUNTIME."
  (interactive)
  (let* ((rt (etaf-export--resolve-runtime runtime))
         (ctx (or (etaf-ext-context 'etaf-export rt)
                  (ignore-errors (etaf-ext-attach 'etaf-export rt)))))
    (etaf-export--open-preview rt ctx)))

;;;###autoload
(cl-defun etaf-export-svg (&optional output-file
                           &key runtime
                                (page-mode etaf-export-default-page-mode)
                                (theme etaf-export-default-theme)
                                (page-numbers etaf-export-page-numbers)
                                (margin etaf-export-margin)
                                (font-family etaf-export-font-family))
  "Export mounted RUNTIME as standalone vector SVG file(s) at OUTPUT-FILE."
  (interactive)
  (etaf-export--validate-options page-mode theme)
  (let* ((rt (etaf-export--resolve-runtime runtime))
         (prompted (and (null output-file) (not noninteractive)))
         (dest (etaf-export--resolve-output-file output-file rt "svg"))
         (ctx (etaf-ext-context 'etaf-export rt))
         (snap (etaf-export--snapshot-runtime rt :theme theme :font-family font-family))
         (rendered (etaf-export--render-svg-pages snap
                                                  :page-mode page-mode
                                                  :margin margin
                                                  :page-numbers page-numbers))
         (svg-pages (plist-get rendered :svg-pages))
         (written (etaf-export--write-svg-files svg-pages dest))
         (result (list :file (car written)
                       :files written
                       :format 'svg
                       :pages (length svg-pages)
                       :page-mode page-mode
                       :theme theme
                       :lines (plist-get snap :line-count)
                       :images (length (plist-get snap :images)))))
    (when (or prompted (called-interactively-p 'interactive))
      (etaf-export--notify-exported ctx result))
    result))

;;;###autoload
(cl-defun etaf-export-pdf (&optional output-file
                           &key runtime
                                (page-mode etaf-export-default-page-mode)
                                (theme etaf-export-default-theme)
                                (page-numbers etaf-export-page-numbers)
                                (margin etaf-export-margin)
                                (font-family etaf-export-font-family))
  "Export mounted RUNTIME to a zero-browser vector PDF at OUTPUT-FILE."
  (interactive)
  (etaf-export--validate-options page-mode theme)
  (let* ((rt (etaf-export--resolve-runtime runtime))
         (prompted (and (null output-file) (not noninteractive)))
         (dest (etaf-export--resolve-output-file output-file rt "pdf"))
         (ctx (etaf-ext-context 'etaf-export rt))
         (result
          (unwind-protect
              (progn
                (when ctx
                  (ignore-errors
                    (etaf-ext-set-activity
                     ctx (list :kind 'task :state 'active
                               :title "正在导出 PDF…"
                               :detail (file-name-nondirectory dest)))))
                (let* ((snap (etaf-export--snapshot-runtime rt :theme theme :font-family font-family))
                       (rendered (etaf-export--render-svg-pages snap
                                                                :page-mode page-mode
                                                                :margin margin
                                                                :page-numbers page-numbers))
                       (svg-pages (plist-get rendered :svg-pages))
                       (pdf-path (etaf-export--compile-pdf svg-pages dest))
                       (bytes (file-attribute-size (file-attributes pdf-path))))
                  (list :file pdf-path
                        :format 'pdf
                        :pages (length svg-pages)
                        :page-mode page-mode
                        :theme theme
                        :bytes bytes
                        :lines (plist-get snap :line-count)
                        :images (length (plist-get snap :images)))))
            (when ctx
              (ignore-errors (etaf-ext-clear-activity ctx))))))
    (when (or prompted (called-interactively-p 'interactive))
      (etaf-export--notify-exported ctx result))
    result))

;;;; `etaf-ext' Command Handlers

(defun etaf-export--cmd-preview (ctx)
  "Open the live vector Export Preview workspace for CTX's Runtime."
  (etaf-export--open-preview (etaf-ext-ctx-runtime ctx) ctx))

(defun etaf-export--cmd-pdf (ctx)
  "Prompt for destination path and export CTX's Runtime as PDF."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (dest (etaf-export--prompt-output-path rt "pdf"))
         (res (etaf-export-pdf dest :runtime rt)))
    (etaf-export--notify-exported ctx res)
    res))

(defun etaf-export--cmd-svg (ctx)
  "Prompt for destination path and export CTX's Runtime as SVG."
  (let* ((rt (etaf-ext-ctx-runtime ctx))
         (dest (etaf-export--prompt-output-path rt "svg"))
         (res (etaf-export-svg dest :runtime rt)))
    (etaf-export--notify-exported ctx res)
    res))

;;;###autoload
(defun etaf-export-register ()
  "Register the standalone `etaf-export' extension inside `etaf-ext'."
  (etaf-ext-define etaf-export
    :name "页面导出 PDF / SVG"
    :version "0.2.1"
    :icon "导"
    :tone 'info
    :prefix-hint "x"
    :description "将任意已挂载 ETAF 渲染页面零浏览器实时预览并导出为真矢量 PDF 或 SVG，支持 A4/Letter 分页、单页长图与强制亮色打印。"
    :activation 'on-command
    :matches (list :apps t
                   :predicate (lambda (_rt meta _buf)
                                (not (memq (plist-get meta :app)
                                           '(etaf-ext-manager etaf-export-preview)))))
    :priority 70
    :debounce 0.1
    :permissions '(keys popup notify storage)
    :commands '((preview :subkey "x" :label "打开导出预览工作台"   :fn etaf-export--cmd-preview)
                (pdf     :subkey "p" :label "导出当前页面为 PDF"   :fn etaf-export--cmd-pdf)
                (svg     :subkey "s" :label "导出当前页面为矢量 SVG" :fn etaf-export--cmd-svg))
    :popup #'etaf-export--popup-view
    :on-theme #'etaf-export--on-theme
    :on-detach #'etaf-export--on-detach))

(etaf-export-register)

(provide 'etaf-export)
;;; etaf-export.el ends here
