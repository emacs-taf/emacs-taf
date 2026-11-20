;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-frames.el --- Baked image-frame recordings

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A baked image recording is a set of still frames plus a small JSON
;; manifest.  This provider reads the manifest, validates every frame file
;; and reports the pixel size and timing to the reel layer.  Frames may come
;; from any renderer that can export stills: an offline browser canvas, a
;; shader preview or a decoder.  Playback replays the files; it never runs
;; the renderer.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'image)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-reel)

(defconst etaf-screensaver-frames--version 1
  "Manifest format version this provider reads.")

(defconst etaf-screensaver-frames--suffix ".frames.json"
  "File name suffix of an image-frame manifest.")

(defun etaf-screensaver-frames-manifest-p (file)
  "Return non-nil when FILE names an image-frame manifest."
  (and (stringp file) (string-suffix-p etaf-screensaver-frames--suffix file)))

(cl-defstruct (etaf-screensaver--frames-reader
               (:constructor etaf-screensaver--frames-reader-new))
  "One validation cursor; it owns metadata only, never a buffer or image."
  file directory remaining data (index 0) (bytes 0))

(cl-defstruct (etaf-screensaver--frames-preparation
               (:constructor etaf-screensaver--frames-preparation-new))
  "One next-page read owned by a presentation, including a deferred failure."
  source key reader data problem done)

(defun etaf-screensaver--frames-read-begin (file)
  "Validate FILE's manifest and return a cursor over its unverified assets."
  (unless (<= (file-attribute-size (file-attributes file)) (* 1024 1024))
    (etaf-screensaver--fail "Frame manifest exceeds 1 MiB: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (let ((manifest (condition-case nil
                        (json-parse-string (buffer-string)
                                           :object-type 'plist :array-type 'list)
                      (error (etaf-screensaver--fail
                              "Frame manifest is not valid JSON: %s" file)))))
      (unless (and (listp manifest)
                   (equal (plist-get manifest :version) etaf-screensaver-frames--version))
        (etaf-screensaver--fail "Unsupported frame manifest version: %s" file))
      (let ((width (plist-get manifest :width))
            (height (plist-get manifest :height))
            (frame-rate (plist-get manifest :frame_rate))
            (names (plist-get manifest :frames)))
        (unless (and (integerp width) (<= 1 width 2048)
                     (integerp height) (<= 1 height 2048)
                     (<= (* width height) 2073600))
          (etaf-screensaver--fail "Frame manifest has no valid bounded pixel size: %s" file))
        (unless (and (numberp frame-rate) (<= 1 frame-rate 120))
          (etaf-screensaver--fail "Frame manifest has no valid frame rate: %s" file))
        (unless (and (proper-list-p names) (<= 1 (length names) 7200)
                     (cl-every (lambda (name)
                                 (and (stringp name) (not (member name '("." "..")))
                                      (not (equal name ""))
                                      (not (string-match-p "[/\\\\\0]" name))))
                               names))
          (etaf-screensaver--fail "Frame manifest needs 1–7200 local basenames: %s" file))
        (let* ((directory (file-name-as-directory
                           (file-truename (file-name-directory (expand-file-name file)))))
               (paths (mapcar (lambda (name) (expand-file-name name directory)) names)))
          (etaf-screensaver--frames-reader-new
           :file file :directory directory :remaining paths
           :data (list :image-frames (vconcat paths)
                       :image-types (make-vector (length paths) nil)
                       :image-size (cons width height)
                       :frame-rate frame-rate
                       :source (or (plist-get manifest :source)
                                   (replace-regexp-in-string
                                    "\\.frames\\'" "" (file-name-base file)))
                       :license (plist-get manifest :license)
                       :assets (cons file paths))))))))

(defun etaf-screensaver--frames-read-step (reader &optional limit deadline)
  "Validate READER's next assets, stopping at LIMIT files or wall DEADLINE.
Nil limits finish synchronously.  Each file is atomic; check the deadline
before its stat/header read.  Reuse one temporary header buffer per chunk."
  (let ((directory (etaf-screensaver--frames-reader-directory reader))
        (types (plist-get (etaf-screensaver--frames-reader-data reader) :image-types))
        (processed 0))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (while (and (etaf-screensaver--frames-reader-remaining reader)
                  (or (null limit) (< processed limit))
                  (or (null deadline) (< (float-time) deadline)))
        (let* ((path (car (etaf-screensaver--frames-reader-remaining reader)))
               (attributes (file-attributes path)))
          ;; Basenames and the canonical root were checked once at begin.
          ;; Only symlinks can leave the bundle; validate their target too.
          (when (stringp (file-attribute-type attributes))
            (let ((target (file-truename path)))
              (unless (file-in-directory-p target directory)
                (etaf-screensaver--fail "Frame file escapes its bundle: %s" path))
              (setq attributes (file-attributes target))))
          (unless (and attributes (null (file-attribute-type attributes))
                       (eq (aref (file-attribute-modes attributes) 0) ?-))
            (etaf-screensaver--fail "Frame file is missing or not regular: %s" path))
          (let ((size (file-attribute-size attributes)))
            (cl-incf (etaf-screensaver--frames-reader-bytes reader) size)
            (unless (and (<= size (* 16 1024 1024))
                         (<= (etaf-screensaver--frames-reader-bytes reader) (* 1024 1024 1024)))
              (etaf-screensaver--fail "Frame bundle exceeds its byte limit: %s"
                                     (etaf-screensaver--frames-reader-file reader))))
          (erase-buffer)
          ;; Recognize content independently of file suffix and host decoders.
          ;; Binary signatures need only a short prefix; textual headers keep
          ;; the same bounded fallback in synchronous and incremental reads.
          (insert-file-contents-literally path nil 0 64)
          (let ((type (or (image-type-from-buffer)
                          (image-type-from-data (buffer-string)))))
            (when (and (null type) (= (buffer-size) 64))
              (goto-char (point-max))
              (insert-file-contents-literally path nil 64 8192)
              (setq type (or (image-type-from-buffer)
                             (image-type-from-data (buffer-string)))))
            (unless type
              (etaf-screensaver--fail "Frame file is not a supported image: %s" path))
            (aset types (etaf-screensaver--frames-reader-index reader) type))
          (pop (etaf-screensaver--frames-reader-remaining reader))
          (cl-incf (etaf-screensaver--frames-reader-index reader))
          (cl-incf processed))))))

(defun etaf-screensaver--frames-read-result (reader)
  "Return READER's metadata only after every asset has been validated."
  (when (etaf-screensaver--frames-reader-remaining reader)
    (etaf-screensaver--fail "Frame validation is incomplete: %s"
                           (etaf-screensaver--frames-reader-file reader)))
  (etaf-screensaver--frames-reader-data reader))

(defun etaf-screensaver--frames-read (file)
  "Read FILE's manifest and synchronously validate every frame asset."
  (let ((reader (etaf-screensaver--frames-read-begin file)))
    (etaf-screensaver--frames-read-step reader)
    (etaf-screensaver--frames-read-result reader)))

(defun etaf-screensaver--frames-prepare-step (preparation deadline)
  "Advance PREPARATION by at most 64 assets before wall-clock DEADLINE.
The caller budgets spare frame time.  Manifest parsing is bounded by its
own size/count limits.  A single file's IO cannot be preempted.  Keep
failures for selection, not the current page."
  (condition-case problem
      (let* ((source (etaf-screensaver--frames-preparation-source preparation))
             (file (nth 2 source)))
        (unless (etaf-screensaver--frames-preparation-key preparation)
          (let* ((key (etaf-screensaver--reel-read-cache-key (car source) file))
                 (cached (assoc key etaf-screensaver--reel-read-cache)))
            (setf (etaf-screensaver--frames-preparation-key preparation) key)
            (if cached
                (setf (etaf-screensaver--frames-preparation-data preparation) (nth 2 cached)
                      (etaf-screensaver--frames-preparation-done preparation) t)
              (setf (etaf-screensaver--frames-preparation-reader preparation)
                    (etaf-screensaver--frames-read-begin file)))))
        (unless (etaf-screensaver--frames-preparation-done preparation)
          (let ((reader (etaf-screensaver--frames-preparation-reader preparation)))
            (etaf-screensaver--frames-read-step reader 64 deadline)
            (unless (etaf-screensaver--frames-reader-remaining reader)
              (setf (etaf-screensaver--frames-preparation-data preparation)
                    (etaf-screensaver--frames-read-result reader)
                    (etaf-screensaver--frames-preparation-reader preparation) nil
                    (etaf-screensaver--frames-preparation-done preparation) t)))))
    (error
     ;; This is a deferred error, not a fallback or a successful cache entry.
     ;; Selection below re-signals it unless the manifest has since changed.
     (setf (etaf-screensaver--frames-preparation-problem preparation) problem
           (etaf-screensaver--frames-preparation-reader preparation) nil
           (etaf-screensaver--frames-preparation-done preparation) t))))

(defun etaf-screensaver--frames-prepare-finish (preparation)
  "Finish PREPARATION at page selection, rechecking its manifest identity.
Only a complete successful read can enter the shared playback cache."
  (let* ((source (etaf-screensaver--frames-preparation-source preparation))
         (file (nth 2 source))
         (key (etaf-screensaver--reel-read-cache-key (car source) file)))
    (if (not (equal key (etaf-screensaver--frames-preparation-key preparation)))
        ;; A changed file (or a not-yet-started job) uses the ordinary reader.
        (etaf-screensaver--reel-read (car source) (nth 1 source) file)
      (when-let* ((problem (etaf-screensaver--frames-preparation-problem preparation)))
        (signal (car problem) (cdr problem)))
      (let ((reader (etaf-screensaver--frames-preparation-reader preparation)))
        (when reader
          (etaf-screensaver--frames-read-step reader)
          (setf (etaf-screensaver--frames-preparation-data preparation)
                (etaf-screensaver--frames-read-result reader)))
        (etaf-screensaver--reel-cache-put
         key (etaf-screensaver--frames-preparation-data preparation))))))

(etaf-screensaver-define-reel-provider 'frames
  :title "Baked image frames"
  :license "See recording manifest"
  :extensions '("frames.json")
  :match #'etaf-screensaver-frames-manifest-p
  :read #'etaf-screensaver--frames-read)

(provide 'etaf-screensaver-frames)
;;; etaf-screensaver-frames.el ends here
