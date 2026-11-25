;;; etaf-export-pdf.el --- Zero-browser vector PDF & SVG export backend -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drives `rsvg-convert -f pdf' to turn rendered SVG pages into multi-page or
;; single-page vector PDFs without any browser, Node.js or Python runtime, and
;; also writes standalone SVG files when requested.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-export-snapshot)
(require 'etaf-export-svg)

(define-error 'etaf-export-error "ETAF export error")

(defvar etaf-export-rsvg-convert-program)

(defun etaf-export--rsvg-executable ()
  "Return absolute path to `rsvg-convert' executable, or nil."
  (let ((prog (or (and (boundp 'etaf-export-rsvg-convert-program)
                       etaf-export-rsvg-convert-program)
                  "rsvg-convert")))
    (or (and (stringp prog) (executable-find prog))
        (and (equal prog "rsvg-convert")
             (cl-find-if #'file-executable-p
                         '("/opt/homebrew/bin/rsvg-convert"
                           "/usr/local/bin/rsvg-convert"
                           "/usr/bin/rsvg-convert"))))))

(defun etaf-export--doctor-report ()
  "Return capability report plist matching `etaf-install-doctor'."
  (let* ((rsvg (etaf-export--rsvg-executable))
         (remedy (if (eq system-type 'darwin)
                     "brew install librsvg"
                   "Install librsvg (e.g. apt install librsvg2-bin)")))
    (list :package 'etaf-export
          :ready (if rsvg t nil)
          :required (list (list "rsvg-convert (vector PDF backend)" (if rsvg t nil) remedy))
          :optional nil)))

(defun etaf-export--default-filename (snapshot extension)
  "Suggest an output path with EXTENSION for SNAPSHOT."
  (let* ((uri (plist-get snapshot :uri))
         (title (or (plist-get snapshot :title) "etaf-page"))
         (from-file (and (stringp uri)
                         (not (string-match-p "\\`https?://" uri))
                         (file-exists-p uri)
                         uri))
         (dir (if from-file (file-name-directory from-file) default-directory))
         (stem (if from-file
                   (file-name-base from-file)
                 (let ((clean (replace-regexp-in-string "[^A-Za-z0-9._\u4e00-\u9fff-]+" "-" title)))
                   (setq clean (string-trim clean "-+" "-+"))
                   (if (string-empty-p clean) "etaf-page" clean)))))
    (expand-file-name (concat stem "." extension) dir)))

(defun etaf-export--write-svg-files (svg-pages output-file)
  "Write SVG-PAGES to OUTPUT-FILE (or numbered siblings when >1 page).
Return list of written file paths."
  (let* ((abs (expand-file-name output-file))
         (dir (file-name-directory abs))
         (base (file-name-sans-extension abs))
         (ext (or (file-name-extension abs) "svg"))
         (total (length svg-pages))
         (written nil))
    (when dir (make-directory dir t))
    (if (= total 1)
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (car svg-pages) nil abs nil 'silent))
          (setq written (list abs)))
      (cl-loop for svg in svg-pages
               for idx from 1
               for path = (format "%s-%02d.%s" base idx ext)
               do (let ((coding-system-for-write 'utf-8-unix))
                    (write-region svg nil path nil 'silent))
               do (push path written))
      (setq written (nreverse written)))
    written))

(defun etaf-export--compile-pdf (svg-pages output-file)
  "Compile SVG-PAGES into a single vector PDF at OUTPUT-FILE via `rsvg-convert'."
  (let ((rsvg (etaf-export--rsvg-executable)))
    (unless rsvg
      (signal 'etaf-export-error
              (list "rsvg-convert not found; install librsvg (macOS: brew install librsvg)")))
    (let* ((abs (expand-file-name output-file))
           (dir (file-name-directory abs))
           (tmp-dir (make-temp-file "etaf-export-svg-" t))
           (svg-paths nil))
      (when dir (make-directory dir t))
      (unwind-protect
          (progn
            (cl-loop for svg in svg-pages
                     for idx from 1
                     for path = (expand-file-name (format "page-%04d.svg" idx) tmp-dir)
                     do (let ((coding-system-for-write 'utf-8-unix))
                          (write-region svg nil path nil 'silent))
                     do (push path svg-paths))
            (setq svg-paths (nreverse svg-paths))
            (with-temp-buffer
              (let ((exit-code
                     (apply #'call-process rsvg nil t nil
                            "-f" "pdf" "-o" abs svg-paths)))
                (unless (eql exit-code 0)
                  (signal 'etaf-export-error
                          (list (format "rsvg-convert failed (exit %s): %s"
                                        exit-code (string-trim (buffer-string))))))))
            (unless (and (file-exists-p abs) (> (file-attribute-size (file-attributes abs)) 32))
              (signal 'etaf-export-error (list "Generated PDF file is empty or missing" abs)))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally abs nil 0 8)
              (unless (string-prefix-p "%PDF-" (buffer-string))
                (signal 'etaf-export-error (list "Output file does not have a valid PDF header" abs))))
            abs)
        (ignore-errors (delete-directory tmp-dir t))))))

(provide 'etaf-export-pdf)
;;; etaf-export-pdf.el ends here
