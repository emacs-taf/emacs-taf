;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-reel-tests.el --- Recording adapter acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Drive the public reel provider, registration, playback and import APIs.
;; Provider data uses temporary files so no network or external tool runs.
;; The bundled recordings under lisp/reels were produced once with Terminal
;; Text Effects 0.15.0 (commit 6dbc34a0) from the text "ETAF" on an 80x24
;; canvas at 20 fps; tests/fixtures/tte/bad-row.tterec is a hand-built
;; recording whose first row is two cells wide instead of three.  Image
;; fixtures under tests/fixtures/frames are two 40x20 PNGs and a manifest.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-screensaver)

(defconst etaf-screensaver-reel-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file and its fixtures.")

(defun etaf-screensaver-reel-tests--fixture (name)
  "Return the path of fixture NAME under tests/fixtures."
  (expand-file-name (format "fixtures/%s" name)
                    etaf-screensaver-reel-tests--directory))

(defun etaf-screensaver-reel-tests--bundled (name)
  "Return the path of the bundled recording NAME under lisp/reels."
  (expand-file-name (format "reels/%s" name)
                    (file-name-directory (locate-library "etaf-screensaver-loader"))))

(defmacro etaf-screensaver-reel-tests--clean (&rest body)
  "Run BODY with isolated configuration and guaranteed presentation cleanup."
  (declare (indent 0))
  `(let ((etaf-screensaver-seed 4242)
         (etaf-screensaver-scene-options nil)
         (etaf-screensaver-scene-duration 30)
         (etaf-screensaver-max-frame-rate 60)
         (etaf-screensaver-idle-delay 300))
     (etaf-screensaver-mode -1)
     (set-window-configuration (current-window-configuration))
     (unwind-protect (progn ,@body)
       (etaf-screensaver-mode -1)
       (etaf-screensaver-stop))))

(defun etaf-screensaver-reel-tests--text (buffer)
  "Read BUFFER without display properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-screensaver-reel-tests--provider (id frames width height
                                                 &optional durations ansi)
  "Register test provider ID serving FRAMES of WIDTH by HEIGHT."
  (etaf-screensaver-define-reel-provider
   id
   :title "Reel test provider"
   :license "Test license"
   :extensions '("testreel")
   :match (lambda (file) (string-suffix-p ".testreel" file))
   :read (lambda (_file)
           (list :width width :height height :frame-rate 20 :ansi ansi
                 :durations durations :frames frames :source "test"))))

(defun etaf-screensaver-reel-tests--file ()
  "Create the placeholder recording file reused by fake providers."
  (make-temp-file "reel-test" nil ".testreel"))

(ert-deftest etaf-screensaver-reel-tests-playback-follows-recording ()
  "Registered reels play their frames in recording order and loop."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (etaf-screensaver-reel-tests--provider
       'reel-test-pulse (vector "AAAA\nAAAA" "BBBB\nBBBB") 4 2 [0.6 0.6])
      (etaf-screensaver-register-reel
       (list :id 'reel-test-pulse-reel :provider 'reel-test-pulse
             :recording file :title "Pulse" :frame-rate 20))
      (let ((info (etaf-screensaver-scene-info 'reel-test-pulse-reel)))
        (should (equal (plist-get info :title) "Pulse"))
        (should (= (plist-get info :frame-rate) 20))
        (should (memq 'reel (plist-get info :tags)))
        (should (memq 'reel-test-pulse (plist-get info :tags))))
      (let ((buffer (etaf-screensaver-start 'reel-test-pulse-reel))
            (deadline (+ (float-time) 3)))
        (should (string-match-p "AAAA" (etaf-screensaver-reel-tests--text buffer)))
        (while (and (< (float-time) deadline)
                    (not (string-match-p "BBBB" (etaf-screensaver-reel-tests--text buffer))))
          (sleep-for 0.02))
        (should (string-match-p "BBBB" (etaf-screensaver-reel-tests--text buffer)))
        (setq deadline (+ (float-time) 3))
        (while (and (< (float-time) deadline)
                    (not (string-match-p "AAAA" (etaf-screensaver-reel-tests--text buffer))))
          (sleep-for 0.02))
        (should (string-match-p "AAAA" (etaf-screensaver-reel-tests--text buffer)))
        (etaf-screensaver-stop)
        (should-not (plist-get (etaf-screensaver-status) :active))))))

(ert-deftest etaf-screensaver-reel-tests-ansi-runs-keep-independent-attributes ()
  "Later SGR changes and resets never recolor or restyle preceding runs."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (etaf-screensaver-reel-tests--provider
       'reel-test-sgr-runs
       (vector (concat "\e[;31mA\e[32mB\e[1mC\e[22mD\e[38;2;1;2;3m中"
                       "\e[38;5;202mE\e[39mF\e[48;2;4;5;6mG\e[49mH\e[mI"))
       11 1 nil t)
      (etaf-screensaver-register-reel
       (list :id 'reel-test-sgr-runs :provider 'reel-test-sgr-runs :recording file))
      (let* ((buffer (etaf-screensaver-start 'reel-test-sgr-runs))
             (text (etaf-screensaver-reel-tests--text buffer))
             (start (string-match "ABCD中EFGHI" text)))
        (should start)
        (with-current-buffer buffer
          (cl-loop for expected in '("#cd0000" "#00cd00" "#00cd00" "#00cd00"
                                      "#010203" "#ff5f00")
                   for index from 0
                   do (let* ((faces (get-text-property (+ (point-min) start index) 'face))
                             (color (cl-loop for face in faces
                                             when (and (listp face) (plist-get face :foreground))
                                             return (plist-get face :foreground))))
                        (should (equal color expected))))
          (dolist (check '((2 :weight bold t) (3 :weight bold nil)
                           (6 :foreground "#ff5f00" nil)
                           (7 :background "#040506" t) (8 :background "#040506" nil)
                           (9 :foreground "#ff5f00" nil)))
            (let* ((faces (get-text-property (+ (point-min) start (car check)) 'face))
                   (present (cl-some (lambda (face)
                                       (and (listp face)
                                            (equal (plist-get face (nth 1 check)) (nth 2 check))))
                                     faces)))
              (should (eq (not (null present)) (nth 3 check))))))))))

(ert-deftest etaf-screensaver-reel-tests-wide-ansi-frames-keep-colors ()
  "ANSI frames with wide characters publish centered colored cells."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (etaf-screensaver-reel-tests--provider
       'reel-test-unicode (vector "\e[31m中文\e[0mA B") 7 1 nil t)
      (etaf-screensaver-register-reel
       (list :id 'reel-test-unicode-reel :provider 'reel-test-unicode
             :recording file :title "Unicode" :frame-rate 20))
      (let* ((buffer (etaf-screensaver-start 'reel-test-unicode-reel))
             (status (etaf-screensaver-status))
             (text (etaf-screensaver-reel-tests--text buffer))
             (position (string-match "中文A B" text)))
        (should position)
        (with-current-buffer buffer
          (let ((face (get-text-property (+ (point-min) position) 'face)))
            (should (cl-some (lambda (spec)
                               (and (listp spec) (equal (plist-get spec :foreground) "#cd0000")))
                             face))))
        (let* ((metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
               (expected (* (plist-get status :columns) (plist-get metrics :char-width))))
          (with-current-buffer buffer
            (dolist (row (split-string (buffer-substring (point-min) (point-max)) "\n" t))
              (let ((width (etaf-string-pixel-width row)))
                (should (= width expected))))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-reel-tests-imports-a-recording ()
  "Importing a recording copies it, writes a reel spec and plays it."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "reel-import-" t))
           (source (expand-file-name "beams.tterec" directory))
           (target (expand-file-name "imported" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--bundled "beams.tterec")
                       source)
            (let ((report (etaf-screensaver-import-recording source target)))
              (should (eq (plist-get report :status) 'imported))
              (should (eq (plist-get report :provider) 'tte))
              (should (= (plist-get report :width) 80))
              (should (= (plist-get report :height) 24))
              (should (= (plist-get report :frame-rate) 20))
              (should (= (plist-get report :frame-count) 334))
              (should (equal (plist-get report :license) "MIT"))
              (should (memq 'truecolor (plist-get report :colors)))
              (should (file-regular-p (plist-get report :output)))
              (should (file-regular-p (plist-get report :recording))))
            (should (= (etaf-screensaver-load-scenes (list target)) 1))
            (let ((info (etaf-screensaver-scene-info 'tte-beams)))
              (should (equal (plist-get info :title) "Terminal Text Effects: beams"))
              (should (= (plist-get info :frame-rate) 20)))
            (let ((buffer (etaf-screensaver-start 'tte-beams)))
              ;; Beams paints its word well into the recording; wait for it
              ;; rather than assuming the first frame already shows text.
              (let ((deadline (+ (float-time) 10)))
                (while (and (< (float-time) deadline)
                            (not (string-match-p
                                  "ETAF" (etaf-screensaver-reel-tests--text buffer))))
                  (sleep-for 0.05)))
              (should (string-match-p "ETAF" (etaf-screensaver-reel-tests--text buffer)))
              (etaf-screensaver-stop)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-batch-report-classifies-files ()
  "A batch import separates compatible, unrecognized and invalid files."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "reel-batch-" t))
           (target (expand-file-name "imported" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--bundled "beams.tterec")
                       (expand-file-name "good.tterec" directory))
            (with-temp-file (expand-file-name "notes.txt" directory)
              (insert "not a recording"))
            (let ((data (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally
                           (etaf-screensaver-reel-tests--bundled "beams.tterec"))
                          (buffer-substring-no-properties (point-min) (point-max)))))
              (with-temp-file (expand-file-name "wrong.tterec" directory)
                (set-buffer-multibyte nil)
                (insert "X" (substring data 1)))
              (with-temp-file (expand-file-name "cut.tterec" directory)
                (set-buffer-multibyte nil)
                (insert (substring data 0 (/ (length data) 2)))))
            (let ((report (etaf-screensaver-import-directory directory target)))
              (should (= (length (plist-get report :imported)) 1))
              (should (= (length (plist-get report :skipped)) 1))
              (should (= (length (plist-get report :failed)) 1))
              (let ((imported (car (plist-get report :imported)))
                    (skipped (car (plist-get report :skipped)))
                    (failed (car (plist-get report :failed))))
                (should (= (plist-get imported :frame-count) 334))
                (should (equal (file-name-nondirectory (plist-get imported :file)) "good.tterec"))
                (should (eq (plist-get skipped :status) 'skipped))
                (should (equal (file-name-nondirectory (plist-get skipped :file)) "wrong.tterec"))
                (should (eq (plist-get failed :status) 'failed))
                (should (equal (file-name-nondirectory (plist-get failed :file)) "cut.tterec"))
                (should (stringp (plist-get failed :reason)))))
            (should (= (etaf-screensaver-load-scenes (list target)) 1))
            (should (memq 'tte-beams (etaf-screensaver-scenes))))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-rejects-invalid-recordings ()
  "Invalid recordings signal etaf-screensaver-error and write nothing."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "reel-invalid-" t))
           (target (expand-file-name "imported" directory))
           (data (with-temp-buffer
                   (set-buffer-multibyte nil)
                   (insert-file-contents-literally
                    (etaf-screensaver-reel-tests--bundled "beams.tterec"))
                   (buffer-substring-no-properties (point-min) (point-max)))))
      (unwind-protect
          (progn
            (let ((versioned (expand-file-name "version.tterec" directory)))
              (with-temp-file versioned
                (set-buffer-multibyte nil)
                (insert (substring data 0 6) "\x02" (substring data 7)))
              (let ((error (should-error (etaf-screensaver-import-recording versioned target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "version" (car (cdr error))))))
            (let ((truncated (expand-file-name "truncated.tterec" directory)))
              (with-temp-file truncated
                (set-buffer-multibyte nil)
                (insert (substring data 0 (/ (length data) 2))))
              (let ((error (should-error (etaf-screensaver-import-recording truncated target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "damaged\\|truncated\\|compressed"
                                        (car (cdr error))))))
            (let ((error (should-error (etaf-screensaver-import-recording
                                        (etaf-screensaver-reel-tests--fixture
                                         "tte/bad-row.tterec")
                                        target)
                                       :type 'etaf-screensaver-error)))
              (should (string-match-p "cells wide" (car (cdr error)))))
            (should-not (file-directory-p target)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-loader-skips-broken-reels ()
  "A reel spec with a missing recording reports and skips independently."
  (etaf-screensaver-reel-tests--clean
    (let ((directory (make-temp-file "reel-loader-" t))
          (file (etaf-screensaver-reel-tests--file)))
      (unwind-protect
          (progn
            (etaf-screensaver-reel-tests--provider
             'reel-test-loader (vector "OK\nOK") 2 1)
            (etaf-screensaver-register-reel
             (list :id 'reel-test-loader-reel :provider 'reel-test-loader
                   :recording file :frame-rate 20))
            (with-temp-file (expand-file-name "missing.esr" directory)
              (prin1 (list :id 'reel-test-missing :provider 'reel-test-loader
                           :recording (expand-file-name "absent.testreel" directory)
                           :frame-rate 20)
                     (current-buffer)))
            (let ((loaded (etaf-screensaver-load-scenes (list directory))))
              (should (= loaded 0)))
            (should-not (memq 'reel-test-missing (etaf-screensaver-scenes))))
        (delete-directory directory t)))))

(defun etaf-screensaver-reel-tests--display-image (buffer)
  "Return the image file BUFFER displays, or nil."
  (with-current-buffer buffer
    (let ((position (point-min)) file)
      (while (and (< position (point-max)) (null file))
        (let* ((display (get-text-property position 'display))
               (image (car-safe (cdr-safe display))))
          (when (eq (car-safe image) 'image)
            (setq file (image-property image :file))))
        (setq position (next-single-property-change position 'display nil (point-max))))
      file)))

(defun etaf-screensaver-reel-tests--displays (text)
  "Return TEXT's display values, without copying their descriptors."
  (let ((position 0) displays)
    (while (< position (length text))
      (let ((display (get-text-property position 'display text)))
        (when display (push display displays)))
      (setq position (next-single-property-change position 'display text (length text))))
    (nreverse displays)))

(ert-deftest etaf-screensaver-reel-tests-text-scale-resize ()
  "Recorded Unicode text keeps movement, source characters and resize geometry."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file))
          (etaf-screensaver-reel-text-scale 3))
      (unwind-protect
          (progn
            (etaf-screensaver-reel-tests--provider
             'reel-test-scalable
             (vector (concat "        \n\e[31m ▅▆▇█▂  \e[0m\n        ")
                     (concat "        \n\e[34m E中AF  \e[0m\n        "))
             8 3 [0.3 0.3] t)
            (etaf-screensaver-register-reel
             (list :id 'reel-test-scalable-text :provider 'reel-test-scalable :recording file))
            (let ((buffer (etaf-screensaver-start '(:scene reel-test-scalable-text :presentation card))))
              ;; The new value only applies to the next start, including later
              ;; pages.  Existing glyph geometry stays on its original policy.
              (setq etaf-screensaver-reel-text-scale 1)
              (dolist (margins '((10 10) (3 3) (0 0)))
                (apply #'set-window-margins nil margins)
                (etaf-screensaver-reel-tests--wait
                 (lambda ()
                   (and (plist-get (etaf-screensaver-status) :active)
                        (= (plist-get (etaf-screensaver-status) :columns) (1- (window-body-width)))
                        (string-match-p "E中AF" (etaf-screensaver-reel-tests--text buffer)))))
                (let* ((metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
                       (text (with-current-buffer buffer (buffer-substring (point-min) (point-max))))
                       (images (delq nil
                                     (mapcar (lambda (display)
                                               (let ((image (cadr display)))
                                                 (and (eq (car-safe image) 'image) image)))
                                             (etaf-screensaver-reel-tests--displays text))))
                       (has-images (not (null images)))
                       (svg (and (display-graphic-p) (image-type-available-p 'svg)))
                       (expected (* (plist-get (etaf-screensaver-status) :columns)
                                    (plist-get metrics :char-width))))
                  (should (eq has-images svg))
                  (dolist (image images)
                    (let ((height (image-property image :max-height)))
                      (should (= height (* 3 (plist-get metrics :line-height))))))
                  (dolist (row (split-string text "\n" t))
                    (let ((width (etaf-string-pixel-width row)))
                      (should (= width expected))))))
              (etaf-screensaver-stop)))
        (etaf-screensaver-stop)
        (delete-file file)))))

(ert-deftest etaf-screensaver-reel-tests-scaled-transient-kept ()
  "Enlarging the settled subject keeps a transient glyph beside it."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file))
          (etaf-screensaver-reel-text-scale 3))
      (unwind-protect
          (progn
            (etaf-screensaver-reel-tests--provider
             'reel-test-transient
             (vector "A       " "   ETAF " "   ETAF " "        ")
             8 1 [1.0 1.0 1.0 1.0])
            (etaf-screensaver-register-reel
             (list :id 'reel-test-transient-text :provider 'reel-test-transient :recording file))
            (let ((buffer (etaf-screensaver-start
                           '(:scene reel-test-transient-text :duration 30))))
              ;; The first frame's A sits left of the settled subject.  It
              ;; must stay visible while that subject is enlarged.  The blank
              ;; closing frame must not hide the subject bounds.
              (should (string-match-p "A" (etaf-screensaver-reel-tests--text buffer)))
              (should
               (etaf-screensaver-reel-tests--wait
                (lambda ()
                  (with-current-buffer buffer
                    (cl-some (lambda (display)
                               (eq (car-safe (cadr display)) 'image))
                             (etaf-screensaver-reel-tests--displays
                              (buffer-substring (point-min) (point-max))))))))
              (etaf-screensaver-stop)))
        (etaf-screensaver-stop)
        (delete-file file)))))

(ert-deftest etaf-screensaver-reel-tests-scaled-color-snapshots ()
  "A color-only text frame changes color without recoloring an older snapshot."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file))
          (etaf-screensaver-reel-text-scale 3))
      (unwind-protect
          (progn
            (etaf-screensaver-reel-tests--provider
             'reel-test-scaled-color
             ["\e[38;2;17;34;51mETAF\e[0m" "\e[38;2;170;187;204mETAF\e[0m"]
             4 1 [0.3 0.3] t)
            (etaf-screensaver-register-reel
             (list :id 'reel-test-scaled-color-text :provider 'reel-test-scaled-color :recording file))
            (let* ((buffer (etaf-screensaver-start '(:scene reel-test-scaled-color-text :presentation full)))
                   (snapshot (with-current-buffer buffer (buffer-substring (point-min) (point-max)))))
              (cl-labels ((foreground (text)
                            (let* ((position (string-match "ETAF" text))
                                   (face (and position (get-text-property position 'face text)))
                                   (faces (if (keywordp (car-safe face)) (list face) face)))
                              (cl-some (lambda (part) (plist-get part :foreground)) faces))))
                (let ((initial (foreground snapshot)))
                  (should (equal initial "#112233")))
                (etaf-screensaver-reel-tests--wait
                 (lambda ()
                   (and (plist-get (etaf-screensaver-status) :active)
                        (with-current-buffer buffer
                          (equal (foreground (buffer-substring (point-min) (point-max))) "#aabbcc")))))
                (let ((retained (foreground snapshot)))
                  (should (equal retained "#112233"))))))
        (etaf-screensaver-stop)
        (delete-file file)))))

(ert-deftest etaf-screensaver-reel-tests-concurrent-text-overview ()
  "Automatic concurrent text stays native; an explicit scale still applies."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (unwind-protect
          (progn
            (etaf-screensaver-reel-tests--provider 'reel-test-overview ["ETAF"] 4 1)
            (etaf-screensaver-register-reel
             (list :id 'reel-test-overview-text :provider 'reel-test-overview :recording file))
            (dolist (scale '(auto 2))
              (let* ((etaf-screensaver-reel-text-scale scale)
                     (buffer (etaf-screensaver-start
                              '(:presentation mosaic :scenes (reel-test-overview-text reel-test-overview-text))))
                     (status (etaf-screensaver-status))
                     (text (with-current-buffer buffer (buffer-substring (point-min) (point-max))))
                     (has-images (not (null
                                       (cl-some (lambda (display) (eq (car-safe (cadr display)) 'image))
                                                (etaf-screensaver-reel-tests--displays text)))))
                     (expected (and (eq scale 2) (display-graphic-p) (image-type-available-p 'svg)))
                     (has-text (not (null (string-match-p "ETAF" (substring-no-properties text))))))
                (should (= (length (plist-get status :works)) 2))
                (should has-text)
                (should (eq has-images expected)))
              (etaf-screensaver-stop)))
        (etaf-screensaver-stop)
        (delete-file file)))))

(ert-deftest etaf-screensaver-reel-tests-invalid-text-scale ()
  "Invalid text scales fail before takeover without changing the caller buffer."
  (etaf-screensaver-reel-tests--clean
    (let ((editor (window-buffer)))
      (dolist (value '(0 25 nil invalid))
        (let ((etaf-screensaver-reel-text-scale value))
          (should-error (etaf-screensaver-start 'tte-beams) :type 'etaf-screensaver-error)
          (let ((active (plist-get (etaf-screensaver-status) :active))
                (restored (eq (window-buffer) editor)))
            (should-not active)
            (should restored)))))))

(ert-deftest etaf-screensaver-reel-tests-images-preserve-native-size ()
  "Image works fit without enlargement and retain their full native extent."
  (etaf-screensaver-reel-tests--clean
    (etaf-screensaver-register-reel
     (list :id 'reel-test-native-size :provider 'frames
           :recording (etaf-screensaver-reel-tests--fixture "frames/sample.frames.json")))
    (dolist (style '(full card band mosaic))
      (let* ((buffer (etaf-screensaver-start
                      (list :scene 'reel-test-native-size :presentation style)))
             (text (with-current-buffer buffer (buffer-substring (point-min) (point-max))))
             (displays (etaf-screensaver-reel-tests--displays text))
             (images (cl-remove-if-not (lambda (display) (eq (car-safe (cadr display)) 'image)) displays))
             (image (cadar images))
             (scale (image-property image :scale))
             (height (image-property image :max-height)))
        (should images)
        (should (<= scale 1.0))
        (should (= height (* 20 scale)))
        (should (= (image-property image :max-width) (* 40 scale)))
        (when (eq style 'full)
          (should (= scale 1.0))
          (should (= height 20)))
        (let ((covered 0))
          (dolist (display images)
            (let ((slice (car display)))
              (should (= (nth 2 slice) covered))
              (cl-incf covered (nth 4 slice))))
          (should (= covered height))))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-reel-tests-image-frames-advance ()
  "Images advance in every layout without changing earlier publication values."
  (etaf-screensaver-reel-tests--clean
    (let ((manifest (etaf-screensaver-reel-tests--fixture "frames/sample.frames.json")))
      (etaf-screensaver-register-reel
       (list :id 'reel-test-image :provider 'frames :recording manifest
             :title "Baked fixture" :frame-rate 10))
      (dolist (style '(full card band mosaic))
        (let* ((buffer (etaf-screensaver-start
                        (list :presentation style :scenes
                              (make-list (if (eq style 'mosaic) 4 1) 'reel-test-image))))
               (first (etaf-screensaver-reel-tests--display-image buffer))
               (snapshot (with-current-buffer buffer (buffer-substring (point-min) (point-max))))
               (expected (copy-tree (etaf-screensaver-reel-tests--displays snapshot)))
               (deadline (+ (float-time) 3)))
          (should (member (file-name-nondirectory first)
                          '("frame-a.png" "frame-b.png")))
          (while (and (< (float-time) deadline)
                      (equal (etaf-screensaver-reel-tests--display-image buffer) first))
            (sleep-for 0.02))
          (let ((second (etaf-screensaver-reel-tests--display-image buffer))
                (retained (etaf-screensaver-reel-tests--displays snapshot)))
            (should (member (file-name-nondirectory second)
                            '("frame-a.png" "frame-b.png")))
            (should-not (equal first second))
            (should expected)
            (should (equal retained expected)))
          (etaf-screensaver-stop)
          (should-not (plist-get (etaf-screensaver-status) :active)))))))

(ert-deftest etaf-screensaver-reel-tests-imports-frame-bundle ()
  "Importing a frame bundle copies every file and plays the reel."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "frames-import-" t))
           (source (expand-file-name "sample.frames.json" directory))
           (target (expand-file-name "imported" directory)))
      (unwind-protect
          (progn
            (dolist (name '("sample.frames.json" "frame-a.png" "frame-b.png"))
              (copy-file (etaf-screensaver-reel-tests--fixture (format "frames/%s" name))
                         (expand-file-name name directory)))
            (let ((report (etaf-screensaver-import-recording source target)))
              (should (eq (plist-get report :kind) 'image))
              (should (equal (plist-get report :image-size) '(40 . 20)))
              (should (= (plist-get report :frame-count) 2))
              (should (equal (file-name-nondirectory (plist-get report :recording))
                             "sample.frames.json"))
              (should (file-regular-p (plist-get report :output)))
              (dolist (name '("sample.frames.json" "frame-a.png" "frame-b.png"))
                (should (file-regular-p
                         (expand-file-name (format "frames-sample/%s" name) target)))))
            (should (= (etaf-screensaver-load-scenes (list target)) 1))
            (let ((buffer (etaf-screensaver-start 'frames-sample)))
              (should (etaf-screensaver-reel-tests--display-image buffer))
              (etaf-screensaver-stop)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-content-signatures-and-long-headers ()
  "Imports recognize content, fall back for long headers and revalidate assets."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "frames-headers-" t))
           (manifest (expand-file-name "headers.frames.json" directory))
           (vector-file (expand-file-name "vector.bin" directory))
           (target (expand-file-name "imported" directory))
           (rejected (expand-file-name "rejected" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png")
                       (expand-file-name "png.jpg" directory))
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/large-a.jpg")
                       (expand-file-name "jpeg.png" directory))
            (with-temp-file vector-file
              (insert "<?xml version=\"1.0\"?><!--" (make-string 320 ?\s)
                      "--><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\">"
                      "<rect width=\"40\" height=\"20\" fill=\"red\"/></svg>"))
            (with-temp-file manifest
              (insert (json-encode '(:version 1 :width 40 :height 20 :frame_rate 10
                                    :frames ["png.jpg" "jpeg.png" "vector.bin"]))))
            ;; Fill the normal playback cache before importing the same bundle.
            (etaf-screensaver-register-reel
             (list :id 'reel-test-headers :provider 'frames :recording manifest))
            (etaf-screensaver-start '(:scene reel-test-headers :duration 30))
            (etaf-screensaver-stop)
            (let ((report (etaf-screensaver-import-recording manifest target)))
              (should (eq (plist-get report :kind) 'image))
              (should (= (plist-get report :frame-count) 3))
              (dolist (name '("png.jpg" "jpeg.png" "vector.bin"))
                (should (file-regular-p
                         (expand-file-name (concat "frames-headers/" name) target)))))
            ;; A valid signature beyond the supported header bound must not
            ;; trigger an unbounded read or reuse of cached validation.
            (with-temp-file vector-file
              (insert "<!--" (make-string 8192 ?\s)
                      "--><svg xmlns=\"http://www.w3.org/2000/svg\"/>"))
            (let ((problem (should-error
                            (etaf-screensaver-import-recording manifest rejected)
                            :type 'etaf-screensaver-error)))
              (should (string-match-p "supported image" (cadr problem))))
            (should-not (file-exists-p rejected)))
        (etaf-screensaver-stop)
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-rejects-broken-frame-bundles ()
  "Missing frames, non-images and bad JSON signal and write nothing."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "frames-invalid-" t))
           (target (expand-file-name "imported" directory)))
      (unwind-protect
          (progn
            (let ((manifest (expand-file-name "missing.frames.json" directory)))
              (with-temp-file manifest
                (insert "{\"version\":1,\"width\":40,\"height\":20,\"frame_rate\":10,"
                        "\"frames\":[\"absent.png\"]}"))
              (let ((error (should-error (etaf-screensaver-import-recording manifest target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "missing" (car (cdr error))))))
            (with-temp-file (expand-file-name "not-image.png" directory)
              (insert "not an image"))
            (let ((manifest (expand-file-name "broken.frames.json" directory)))
              (with-temp-file manifest
                (insert "{\"version\":1,\"width\":40,\"height\":20,\"frame_rate\":10,"
                        "\"frames\":[\"not-image.png\"]}"))
              (let ((error (should-error (etaf-screensaver-import-recording manifest target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "supported image" (car (cdr error))))))
            (let ((manifest (expand-file-name "json.frames.json" directory)))
              (with-temp-file manifest (insert "not json"))
              (let ((error (should-error (etaf-screensaver-import-recording manifest target)
                                         :type 'etaf-screensaver-error)))
                (should (string-match-p "valid JSON" (car (cdr error))))))
            (should-not (file-exists-p target)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-bounded-frame-import ()
  "Escaping paths and oversized declarations fail before writing imports."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "frames-bounds-" t))
           (bundle (expand-file-name "bundle" directory))
           (target (expand-file-name "imported" directory))
           (manifest (expand-file-name "test.frames.json" bundle))
           (outside (expand-file-name "outside.png" directory)))
      (unwind-protect
          (progn
            (make-directory bundle)
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png") outside)
            (copy-file outside (expand-file-name "frame.png" bundle))
            (make-symbolic-link outside (expand-file-name "escape.png" bundle))
            (dolist (overrides
                     (list '(:width 2049) '(:height 2049)
                           '(:width 2048 :height 2048) '(:frame_rate 121)
                           '(:frames ["../outside.png"]) '(:frames ["..\\outside.png"])
                           (list :frames (vector outside)) '(:frames ["escape.png"])
                           (list :frames (make-vector 7201 "frame.png"))))
              (let ((data (list :version 1 :width 40 :height 20
                                :frame_rate 10 :frames ["frame.png"])))
                (while overrides
                  (setq data (plist-put data (pop overrides) (pop overrides))))
                (with-temp-file manifest (insert (json-encode data))))
              (should-error (etaf-screensaver-import-recording manifest target)
                            :type 'etaf-screensaver-error)
              (should-not (file-exists-p target)))
            (with-temp-file manifest (insert (make-string (1+ (* 1024 1024)) ?x)))
            (should-error (etaf-screensaver-import-recording manifest target)
                          :type 'etaf-screensaver-error)
            (should-not (file-exists-p target)))
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-natural-duration ()
  "A reel with frame count and rate registers its full length as duration."
  (etaf-screensaver-reel-tests--clean
    (let ((manifest (etaf-screensaver-reel-tests--fixture "frames/sample.frames.json")))
      (etaf-screensaver-register-reel
       (list :id 'reel-test-natural :provider 'frames :recording manifest
             :frame-rate 10 :frame-count 2 :title "Natural"))
      (etaf-screensaver-start '(:order sequential :scenes (reel-test-natural matrix)))
      (let ((deadline (+ (float-time) 3)))
        (while (and (< (float-time) deadline)
                    (eq (plist-get (etaf-screensaver-status) :scene) 'reel-test-natural))
          (sleep-for 0.02)))
      (should (eq (plist-get (etaf-screensaver-status) :scene) 'matrix))
      (etaf-screensaver-stop))))

(ert-deftest etaf-screensaver-reel-tests-contained-frame-symlinks ()
  "Canonical bundle paths accept internal image links but still reject escapes."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (make-temp-file "frames-links-" t))
           (bundle (expand-file-name "bundle" directory))
           (alias (expand-file-name "bundle-alias" directory))
           (target (expand-file-name "imported" directory))
           (manifest (expand-file-name "linked.frames.json" alias)))
      (unwind-protect
          (progn
            (make-directory bundle)
            (make-symbolic-link bundle alias)
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png")
                       (expand-file-name "frame.png" bundle))
            (make-symbolic-link "frame.png" (expand-file-name "linked.png" bundle))
            (with-temp-file manifest
              (insert (json-encode '(:version 1 :width 40 :height 20
                                    :frame_rate 10 :frames ["linked.png"]))))
            (let* ((report (etaf-screensaver-import-recording manifest target))
                   (status (plist-get report :status)))
              (should (eq status 'imported)))
            (delete-file (expand-file-name "linked.png" bundle))
            (copy-file (expand-file-name "frame.png" bundle)
                       (expand-file-name "outside.png" directory))
            (make-symbolic-link "../outside.png" (expand-file-name "linked.png" bundle))
            (should-error (etaf-screensaver-import-recording
                           manifest (expand-file-name "escaped" directory))
                          :type 'etaf-screensaver-error)
            (should-not (file-exists-p (expand-file-name "escaped" directory))))
        (delete-directory directory t)))))

(defun etaf-screensaver-reel-tests--image-runs (buffer)
  "Return BUFFER's image runs as (ROW PIXEL-X PIXEL-WIDTH SLICE FILE)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((row 0) runs)
        (while (< (point) (point-max))
          (let ((position (point)) (end (line-end-position)))
            (while (< position end)
              (let* ((next (next-single-property-change position 'display nil end))
                     (display (get-text-property position 'display))
                     (image (car-safe (cdr-safe display))))
                (when (eq (car-safe image) 'image)
                  (push (list row (etaf-string-pixel-width
                                   (buffer-substring (line-beginning-position) position))
                              (etaf-string-pixel-width (buffer-substring position next))
                              (car display) (image-property image :file))
                        runs))
                (setq position next))))
          (cl-incf row)
          (forward-line 1))
        (nreverse runs)))))

(defun etaf-screensaver-reel-tests--wait (predicate)
  "Wait at most three seconds for public PREDICATE."
  (let ((deadline (+ (float-time) 3)))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (sleep-for 0.005)))
  (should (funcall predicate)))

(ert-deftest etaf-screensaver-reel-tests-image-resize-recovers-clipped-canvas ()
  "A smaller viewport still receives fitted images when old glyphs are clipped."
  (etaf-screensaver-reel-tests--clean
    (etaf-screensaver-register-reel
     (list :id 'reel-test-resize :provider 'frames
           :recording (etaf-screensaver-reel-tests--fixture "frames/sample.frames.json")
           :title "Resizing images" :frame-rate 20))
    (dolist (style '(full card band mosaic))
      (let ((buffer (etaf-screensaver-start
                     (list :scene 'reel-test-resize :duration 30 :presentation style))))
        ;; The first shrink is below the framed layouts' minimum grid: their
        ;; work and static fragments must still clip to the drawable width.
        (dolist (margins '((10 10) (3 3) (0 0)))
          (apply #'set-window-margins nil margins)
          (let ((columns (1- (window-body-width))))
            (etaf-screensaver-reel-tests--wait
             (lambda ()
               (and (= (plist-get (etaf-screensaver-status) :columns) columns)
                    (etaf-screensaver-reel-tests--image-runs buffer))))
            (let* ((metrics (etaf-display-metrics (etaf-runtime-for-buffer buffer)))
                   (expected (* columns (plist-get metrics :char-width)))
                   (runs (etaf-screensaver-reel-tests--image-runs buffer)))
              (should runs)
              (with-current-buffer buffer
                (dolist (row (split-string (buffer-substring (point-min) (point-max)) "\n" t))
                  (let ((width (etaf-string-pixel-width row)))
                    (should (= width expected))))))))
        (etaf-screensaver-stop)))))

(ert-deftest etaf-screensaver-reel-tests-image-reveal-keeps-margins ()
  "Image reveals preserve blank margins and moving slices in every layout."
  (etaf-screensaver-reel-tests--clean
    (let ((directory (make-temp-file "image-reveal-" t))
          (etaf-screensaver-transition-duration 0.4))
      (unwind-protect
          (progn
            (dolist (name '(outgoing incoming))
              (let ((manifest (expand-file-name (format "%s.frames.json" name) directory)))
                (dolist (frame '(a b))
                  (copy-file (etaf-screensaver-reel-tests--fixture (format "frames/frame-%s.png" frame))
                             (expand-file-name (format "%s-%s.png" name frame) directory)))
                (with-temp-file manifest
                  (insert (json-encode
                           (list :version 1 :width 40 :height 20 :frame_rate 20
                                 :frames (vector (format "%s-a.png" name) (format "%s-b.png" name))))))
                (etaf-screensaver-register-reel
                 (list :id (intern (format "reel-test-%s" name)) :provider 'frames
                       :recording manifest :frame-rate 20 :title (symbol-name name)))))
            (dolist (style '(full card band mosaic))
              (let* ((count (if (eq style 'mosaic) 4 1))
                     (incoming (make-list count '(:scene reel-test-incoming :duration 30)))
                     (buffer (etaf-screensaver-start
                              (list :presentation style :scenes
                                    (append (make-list count '(:scene reel-test-outgoing :duration 0.3))
                                            incoming))))
                     (geometry (mapcar (lambda (run) (cl-subseq run 0 4))
                                       (etaf-screensaver-reel-tests--image-runs buffer))))
                (should geometry)
                (etaf-screensaver-reel-tests--wait
                 (lambda ()
                   (let ((progress (plist-get (etaf-screensaver-status) :transition-progress)))
                     (and progress (<= 0.4 progress 0.7)))))
                (let* ((runs (etaf-screensaver-reel-tests--image-runs buffer))
                       (mixed-geometry (mapcar (lambda (run) (cl-subseq run 0 4)) runs)))
                  (should (equal mixed-geometry geometry))
                  (dolist (name '(outgoing incoming))
                    (should (cl-some (lambda (run) (string-match-p (symbol-name name) (nth 4 run))) runs))))
                (etaf-screensaver-reel-tests--wait
                 (lambda () (null (plist-get (etaf-screensaver-status) :transition-progress))))
                (let* ((runs (etaf-screensaver-reel-tests--image-runs buffer))
                       (settled-geometry (mapcar (lambda (run) (cl-subseq run 0 4)) runs)))
                  (should (equal settled-geometry geometry))
                  (should (cl-every (lambda (run) (string-match-p "incoming" (nth 4 run))) runs))
                  (etaf-screensaver-reel-tests--wait
                   (lambda () (not (equal runs (etaf-screensaver-reel-tests--image-runs buffer))))))
                (let* ((columns (plist-get (etaf-screensaver-status) :columns))
                       (runtime (etaf-runtime-for-buffer buffer))
                       (metrics (etaf-display-metrics runtime))
                       (expected (* columns (plist-get metrics :char-width))))
                  ;; Display runs replace text: their physical footprint, not
                  ;; the number of placeholder characters, must fill the row.
                  (with-current-buffer buffer
                    (save-excursion
                      (goto-char (point-min))
                      (while (< (point) (point-max))
                        (let* ((row (buffer-substring (point) (line-end-position)))
                               (width (etaf-string-pixel-width row)))
                          (should (= width expected)))
                        (forward-line 1)))))
                (etaf-screensaver-stop)
                (let* ((direct (etaf-screensaver-start (list :presentation style :scenes incoming)))
                       (direct-geometry (mapcar (lambda (run) (cl-subseq run 0 4))
                                                (etaf-screensaver-reel-tests--image-runs direct))))
                  (should (equal direct-geometry geometry)))
                (etaf-screensaver-stop))))
        (etaf-screensaver-stop)
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-replay-observes-recording-edits ()
  "Replaying a changed recording publishes its new content, not a cached frame."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (unwind-protect
          (progn
            (etaf-screensaver-define-reel-provider
             'reel-test-edit :title "Editable recording" :license "Test license"
             :extensions '("testreel") :match (lambda (path) (equal path file))
             :read (lambda (path)
                     (with-temp-buffer
                       (insert-file-contents path)
                       (list :width 40 :height 1 :frame-rate 20
                             :frames (vector (buffer-substring-no-properties (point-min) (point-max)))))))
            (with-temp-file file (insert "Original"))
            (etaf-screensaver-register-reel
             (list :id 'reel-test-edit :provider 'reel-test-edit :recording file))
            (dolist (text '("Original" "Original" "Changed recording" "Changed recording"))
              (unless (equal text "Original")
                (with-temp-file file (insert text)))
              (let* ((buffer (etaf-screensaver-start 'reel-test-edit))
                     (visible (etaf-screensaver-reel-tests--text buffer)))
                (should (string-match-p text visible)))
              (etaf-screensaver-stop)))
        (delete-file file)))))

(ert-deftest etaf-screensaver-reel-tests-provider-image-formats ()
  "Image providers may supply formats or omit them; malformed vectors fail."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)) (index 0))
      (unwind-protect
          (dolist (types '(nil [png png] [png] ["png" "png"] [png nil]))
            (let* ((id (intern (format "reel-test-formats-%d" (cl-incf index))))
                   (frames (vector (etaf-screensaver-reel-tests--fixture "frames/frame-a.png")
                                   (etaf-screensaver-reel-tests--fixture "frames/frame-b.png"))))
              (etaf-screensaver-define-reel-provider
               id :title "Image formats" :license "Test license" :extensions '("testreel")
               :match (lambda (path) (equal path file))
               :read (lambda (_path) (list :image-frames frames :image-size '(40 . 20)
                                          :image-types types :frame-rate 20)))
              (etaf-screensaver-register-reel (list :id id :provider id :recording file))
              (if (> index 2)
                  (should-error (etaf-screensaver-start id) :type 'etaf-screensaver-error)
                (let* ((buffer (etaf-screensaver-start id))
                       (visible (etaf-screensaver-reel-tests--display-image buffer)))
                  (should (equal visible (aref frames 0))))
                (etaf-screensaver-stop))))
        (etaf-screensaver-stop)
        (delete-file file)))))

(etaf-screensaver-define-scene reel-test-current
  :frame-rate 60
  :create (lambda (_context) nil)
  :step (lambda (state _context) state)
  :render (lambda (_state _context) '("CURRENT")))

(defun etaf-screensaver-reel-tests--manifest (file names)
  "Write a bounded image manifest FILE naming the fixture assets NAMES."
  (with-temp-file file
    (insert (json-encode (list :version 1 :width 40 :height 20
                              :frame_rate 15 :frames (vconcat names))))))

(ert-deftest etaf-screensaver-reel-tests-queued-frame-errors-are-deferred ()
  "A broken queued bundle reports at selection, without stopping the current work early."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (file-truename (make-temp-file "frames-queued-errors-" t)))
           (good (expand-file-name "good.png" directory))
           (bad (expand-file-name "bad.png" directory))
           (escape (expand-file-name "escape.png" directory))
           (timers (copy-sequence timer-list)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png") good)
            (with-temp-file bad (insert "not an image"))
            (make-symbolic-link (etaf-screensaver-reel-tests--fixture "frames/frame-a.png") escape)
            (dolist (name '("missing.png" "bad.png" "escape.png"))
              (let* ((manifest (expand-file-name (concat name ".frames.json") directory))
                     (path (expand-file-name name directory)))
                (etaf-screensaver-reel-tests--manifest
                 manifest (append (make-list 128 "good.png") (list name)))
                (etaf-screensaver-register-reel
                 (list :id 'reel-test-queued-error :provider 'frames :recording manifest))
                (let ((buffer (etaf-screensaver-start
                               '(:scenes ((:scene reel-test-current :duration 0.75)
                                          reel-test-queued-error)))))
                  (etaf-screensaver-reel-tests--wait
                   (lambda () (>= (or (plist-get (etaf-screensaver-status) :elapsed) 0) 0.2)))
                  (let ((status (etaf-screensaver-status)))
                    (should (eq (plist-get status :scene) 'reel-test-current))
                    (should (= (plist-get status :index) 0))
                    (should (equal (plist-get status :up-next) '(reel-test-queued-error))))
                  (should (string-match-p "CURRENT" (etaf-screensaver-reel-tests--text buffer)))
                  (when (get-buffer "*Warnings*")
                    (should-not (string-match-p (regexp-quote path)
                                                (etaf-screensaver-reel-tests--text
                                                 (get-buffer "*Warnings*")))))
                  (etaf-screensaver-reel-tests--wait
                   (lambda () (not (plist-get (etaf-screensaver-status) :active))))
                  (should-not (buffer-live-p buffer))
                  (should (string-match-p (regexp-quote path)
                                          (etaf-screensaver-reel-tests--text
                                           (get-buffer "*Warnings*")))))))
            (let ((remaining (cl-set-difference timer-list timers)))
              (should-not remaining)))
        (etaf-screensaver-stop)
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-queued-manifest-edits-and-snapshots ()
  "Selection observes a manifest edit but keeps the compiled reel definition."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (file-truename (make-temp-file "frames-queued-edit-" t)))
           (replacement (expand-file-name "replacement.frames.json" directory))
           (second (expand-file-name "second.png" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png")
                       (expand-file-name "first.png" directory))
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-b.png") second)
            (etaf-screensaver-reel-tests--manifest replacement '("first.png"))
            ;; Both a successful preparation and a deferred error must become
            ;; obsolete when the original manifest changes before selection.
            (dolist (initial '("first.png" "absent.png"))
              (let ((manifest (expand-file-name (concat initial ".frames.json") directory)))
                (etaf-screensaver-reel-tests--manifest manifest (make-list 129 initial))
                (etaf-screensaver-register-reel
                 (list :id 'reel-test-queued-edit :provider 'frames :recording manifest))
                (let ((buffer (etaf-screensaver-start
                               '(:scenes ((:scene reel-test-current :duration 0.75)
                                          (:scene reel-test-queued-edit :duration 30))))))
                  (etaf-screensaver-reel-tests--wait
                   (lambda () (>= (or (plist-get (etaf-screensaver-status) :elapsed) 0) 0.2)))
                  (etaf-screensaver-register-reel
                   (list :id 'reel-test-queued-edit :provider 'frames :recording replacement))
                  (etaf-screensaver-reel-tests--manifest manifest '("second.png"))
                  (etaf-screensaver-reel-tests--wait
                   (lambda ()
                     (equal (etaf-screensaver-reel-tests--display-image buffer) second)))
                  (let ((status (etaf-screensaver-status)))
                    (should (eq (plist-get status :scene) 'reel-test-queued-edit))
                    (should (= (plist-get status :index) 1)))
                  (etaf-screensaver-stop)))))
        (etaf-screensaver-stop)
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-queued-mosaic-completes-all-works ()
  "A short outgoing page still validates and selects every incoming mosaic work."
  (etaf-screensaver-reel-tests--clean
    (let ((directory (file-truename (make-temp-file "frames-queued-wall-" t))) ids paths)
      (unwind-protect
          (progn
            (dotimes (index 4)
              (let* ((id (intern (format "reel-test-queued-wall-%d" index)))
                     (name (format "work-%d.png" index))
                     (path (expand-file-name name directory))
                     (manifest (expand-file-name (concat name ".frames.json") directory)))
                (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png") path)
                (etaf-screensaver-reel-tests--manifest manifest (make-list 360 name))
                (etaf-screensaver-register-reel
                 (list :id id :provider 'frames :recording manifest :duration 30))
                (push id ids)
                (push path paths)))
            (setq ids (nreverse ids))
            (let ((buffer
                   (etaf-screensaver-start
                    (list :presentation 'mosaic :scenes
                          (append (make-list 4 '(:scene reel-test-current :duration 0.08)) ids)))))
              (etaf-screensaver-reel-tests--wait
               (lambda () (equal (plist-get (etaf-screensaver-status) :works) ids)))
              (etaf-screensaver-reel-tests--wait
               (lambda () (not (plist-get (etaf-screensaver-status) :transition-progress))))
              (let ((files (mapcar (lambda (run) (nth 4 run))
                                   (etaf-screensaver-reel-tests--image-runs buffer))))
                (dolist (path paths) (should (member path files))))))
        (etaf-screensaver-stop)
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-cancel-queued-read-releases-resources ()
  "High-rate playback stops a large queued read without leaking resources or partial data."
  (etaf-screensaver-reel-tests--clean
    (let* ((directory (file-truename (make-temp-file "frames-queued-cancel-" t)))
           (manifest (expand-file-name "many.frames.json" directory))
           (asset (expand-file-name "frame.png" directory)))
      (unwind-protect
          (progn
            (copy-file (etaf-screensaver-reel-tests--fixture "frames/frame-a.png") asset)
            (etaf-screensaver-reel-tests--manifest manifest (make-list 7200 "frame.png"))
            (etaf-screensaver-register-reel
             (list :id 'reel-test-queued-cancel :provider 'frames :recording manifest))
            (let* ((timers (copy-sequence timer-list))
                   (processes (process-list))
                   (configuration (current-window-configuration))
                   (buffer (etaf-screensaver-start
                            '(:scenes ((:scene reel-test-current :duration 5 :frame-rate 120)
                                       reel-test-queued-cancel))))
                   ;; Inventory after mount's lazy editor setup, but before
                   ;; the first animation callback can start queued IO.
                   (buffers (buffer-list)))
              (etaf-screensaver-reel-tests--wait
               (lambda () (>= (or (plist-get (etaf-screensaver-status) :ticks) 0) 2)))
              (etaf-screensaver-stop)
              (let ((new-timers (cl-set-difference timer-list timers))
                    (new-buffers (cl-set-difference (buffer-list) buffers))
                    (new-processes (cl-set-difference (process-list) processes))
                    (restored (window-configuration-equal-p configuration
                                                             (current-window-configuration))))
                (should-not (buffer-live-p buffer))
                (should-not new-timers)
                (should-not new-buffers)
                (should-not new-processes)
                (should restored)))
            ;; Leave the manifest unchanged: a partial read must never make
            ;; this now-invalid asset look like a validated cache hit.
            (with-temp-file asset (insert "invalid after cancellation"))
            (should-error (etaf-screensaver-start 'reel-test-queued-cancel)
                          :type 'etaf-screensaver-error))
        (etaf-screensaver-stop)
        (delete-directory directory t)))))

(ert-deftest etaf-screensaver-reel-tests-custom-reader-runs-at-selection ()
  "A queued custom provider reads the latest file only when its scene starts."
  (etaf-screensaver-reel-tests--clean
    (let ((file (etaf-screensaver-reel-tests--file)))
      (unwind-protect
          (progn
            (with-temp-file file (insert "EARLY"))
            (etaf-screensaver-define-reel-provider
             'reel-test-late-reader :title "Selection reader" :license "Test license"
             :extensions '("testreel") :match (lambda (path) (equal path file))
             :read (lambda (path)
                     (with-temp-buffer
                       (insert-file-contents path)
                       (list :width 5 :height 1 :frame-rate 15
                             :frames (vector (buffer-string))))))
            (etaf-screensaver-register-reel
             (list :id 'reel-test-late-reader :provider 'reel-test-late-reader :recording file))
            (let ((buffer (etaf-screensaver-start
                           '(:scenes ((:scene reel-test-current :duration 0.75)
                                      (:scene reel-test-late-reader :duration 30))))))
              (etaf-screensaver-reel-tests--wait
               (lambda () (>= (or (plist-get (etaf-screensaver-status) :elapsed) 0) 0.2)))
              (with-temp-file file (insert "LATER"))
              (etaf-screensaver-reel-tests--wait
               (lambda () (string-match-p "LATER" (etaf-screensaver-reel-tests--text buffer))))))
        (etaf-screensaver-stop)
        (delete-file file)))))

(provide 'etaf-screensaver-reel-tests)
;;; etaf-screensaver-reel-tests.el ends here
