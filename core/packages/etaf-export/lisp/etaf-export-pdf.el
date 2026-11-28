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

(defun etaf-export--rsvg-install-hint ()
  "Return a concise platform-specific command to install `rsvg-convert'."
  (pcase system-type
    ('darwin "brew install librsvg")
    ('windows-nt "pacman -S mingw-w64-x86_64-librsvg (MSYS2)")
    (_ "apt install librsvg2-bin / dnf install librsvg2-tools")))

(defun etaf-export--doctor-report ()
  "Return capability report plist matching `etaf-install-doctor'."
  (let* ((rsvg (etaf-export--rsvg-executable))
         (hint (etaf-export--rsvg-install-hint))
         (remedy (format "Install librsvg for PDF export (%s); live preview and SVG export need no external tools."
                         hint)))
    (list :package 'etaf-export
          :ready (if rsvg t nil)
          :required (list (list "rsvg-convert (vector PDF backend)" (if rsvg t nil) remedy))
          :optional nil)))

(defun etaf-export--default-filename-from-meta (uri title extension)
  "Suggest an output path with EXTENSION from runtime URI and TITLE."
  (let* ((title (or title "etaf-page"))
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

(defun etaf-export--default-filename-for-runtime (runtime extension)
  "Suggest an output path with EXTENSION for mounted RUNTIME without snapshotting."
  (let* ((meta (etaf-runtime-meta runtime))
         (buf (etaf-runtime-buffer runtime))
         (uri (plist-get meta :uri))
         (title (or (plist-get meta :title)
                    (and (buffer-live-p buf) (buffer-name buf)))))
    (etaf-export--default-filename-from-meta uri title extension)))

(defun etaf-export--default-filename (snapshot extension)
  "Suggest an output path with EXTENSION for SNAPSHOT."
  (etaf-export--default-filename-from-meta
   (plist-get snapshot :uri)
   (plist-get snapshot :title)
   extension))

(defun etaf-export--prompt-output-path (runtime extension)
  "Prompt interactively for an output path with EXTENSION for RUNTIME.
Confirms before overwriting an existing file."
  (let* ((default-path (etaf-export--default-filename-for-runtime runtime extension))
         (dest (read-file-name (format "导出 %s 到: " (upcase extension))
                               (file-name-directory default-path)
                               default-path nil
                               (file-name-nondirectory default-path))))
    (when (and (file-exists-p dest)
               (not (y-or-n-p (format "文件 %s 已存在，是否覆盖？ "
                                      (file-name-nondirectory dest)))))
      (user-error "已取消导出"))
    dest))

(defun etaf-export--open-file (path)
  "Open exported file PATH with the OS default viewer when interactive."
  (when (and (stringp path) (file-exists-p path) (not noninteractive))
    (cond
     ((and (eq system-type 'darwin) (executable-find "open"))
      (start-process "etaf-export-open" nil "open" (expand-file-name path)))
     ((executable-find "xdg-open")
      (start-process "etaf-export-open" nil "xdg-open" (expand-file-name path)))
     (t
      (browse-url-of-file (expand-file-name path))))))

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
              (list (format "rsvg-convert not found; install librsvg (%s)"
                            (etaf-export--rsvg-install-hint)))))
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
