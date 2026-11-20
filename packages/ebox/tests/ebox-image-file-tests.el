;;; ebox-image-file-tests.el --- Ebox image and file tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-image-placeholder-preparation-reports-size-and-content ()
  (let ((prepared (ebox-image-prepare '(image :type xpm :data "bad")
                                      3 2 :adapter 'placeholder)))
    (should (equal (ebox-image-info prepared)
                   '(:adapter placeholder :converter nil :columns 3 :rows 2)))
    (should (equal (substring-no-properties (ebox-image-content prepared))
                   "...
..."))))

(ert-deftest ebox-image-identical-preparation-reuses-a-screenful-of-images ()
  "A preparation stays cached while other distinct images are prepared.
A screen with more images than the old clear-all threshold must not
re-create every preparation on the next request."
  (let* ((source (list 'image :type 'xpm :data "reused"))
         (first (ebox-image-prepare source 2 1 :adapter 'placeholder))
         (later (cl-loop for index below 96
                         collect
                         (ebox-image-prepare
                          (list 'image :type 'xpm :data (format "later-%d" index))
                          2 1 :adapter 'placeholder))))
    (should (= 96 (length later)))
    (should (eq first (ebox-image-prepare source 2 1 :adapter 'placeholder)))))

(ert-deftest ebox-image-cache-stays-bounded-and-usable-under-churn ()
  "Preparing many distinct images keeps recent preparations usable."
  (let (newest)
    (dotimes (index 400)
      (setq newest
            (ebox-image-prepare
             (list 'image :type 'xpm :data (format "churn-%d" index))
             2 1 :adapter 'placeholder)))
    (should (eq newest
                (ebox-image-prepare '(image :type xpm :data "churn-399")
                                    2 1 :adapter 'placeholder)))
    (should (equal (substring-no-properties (ebox-image-content newest)) ".."))))

(ert-deftest ebox-image-text-converter-result-is-renderable-image-node ()
  (let* ((converted (copy-sequence "▀▀\n▀▀"))
         (converter (lambda (_source _columns _rows)
                      (let ((s (copy-sequence converted)))
                        (dotimes (i (length s))
                          (unless (= (aref s i) ?\n)
                            (put-text-property
                             i (1+ i) 'face
                             '(:foreground "#000000" :background "#ffffff") s)))
                        s)))
         (prepared (ebox-image-prepare '(image :type xpm :data "bad")
                                       2 2 :adapter 'text
                                       :converters (list (cons 'fixture converter))))
         (node (ebox-node-create 'image (list :image prepared))))
    (should (equal (ebox-image-info prepared)
                   '(:adapter text :converter fixture :columns 2 :rows 2)))
    (should (equal (ebox-test-render-text node) "▀▀
▀▀"))
    (should (equal (get-text-property 0 'face (ebox-render node))
                   '(:foreground "#000000" :background "#ffffff")))))

(ert-deftest ebox-node-set-image-repaints-mounted-image-node ()
  (let ((one (ebox-image-prepare '(image :type xpm :data "one") 2 1 :adapter 'placeholder))
        (two (ebox-image-prepare '(image :type xpm :data "two") 3 1 :adapter 'placeholder)))
    (ebox-test-with-mounted (buffer root (ebox-node-create 'image (list :id "img" :image one)))
      (should (equal (ebox-test-buffer-text buffer) ".."))
      (ebox-node-set-image root two)
      (should (equal (ebox-test-buffer-text buffer) "..."))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-node-set-props-repaints-a-same-sized-image-with-other-pixels ()
  "A different preparation of the same size replaces the shown image.
Both preparations have already been laid out, as cached images have."
  (let* ((converter
          (lambda (source _columns _rows)
            (propertize "▀▀" 'face
                        (list :foreground (plist-get (cdr source) :data)
                              :background "#000000"))))
         (converters (list (cons 'fixture converter)))
         (red (ebox-image-prepare '(image :type xpm :data "#ff0000") 2 1
                                  :adapter 'text :converters converters))
         (blue (ebox-image-prepare '(image :type xpm :data "#0000ff") 2 1
                                   :adapter 'text :converters converters)))
    (ebox-render (ebox-node-create 'image (list :image blue)))
    (ebox-test-with-mounted (buffer root (ebox-node-create 'image (list :image red)))
      (ebox-node-set-props root (list :image blue))
      (let ((face (with-current-buffer buffer
                    (get-text-property (point-min) 'face))))
        (should (equal (plist-get face :foreground) "#0000ff")))
      (should (ebox-test-buffer-matches-render-p root buffer)))))

(ert-deftest ebox-image-in-a-wider-box-paints-the-box-background-beside-it ()
  (let* ((image (ebox-image-prepare '(image :type xpm :data "bad") 2 1
                                    :adapter 'placeholder))
         (rendered (ebox-render
                    (ebox-node-create 'column '(:width (px 10) :background-color "#ff0000")
                                      (list (ebox-node-create 'image (list :image image))
                                            "wide")))))
    (should (equal (substring-no-properties rendered) ".. \nwide "))
    (should (equal (get-text-property 2 'display rendered) '(space :width (8))))
    (should (equal (get-text-property 2 'face rendered) '(:background "#ff0000")))))

(ert-deftest ebox-image-slice-cut-at-a-box-edge-keeps-its-visible-part ()
  (let* ((image '(image :type xpm :data "x"))
         (row (propertize " " 'display (list '(slice 0 16 40 16) image)))
         (rendered (ebox-render
                    (ebox-node-create 'column '(:width (px 25) :wrap-mode none)
                                      (list row)))))
    (should (equal (get-text-property 0 'display rendered)
                   (list '(slice 0 16 25 16) image)))))

(ert-deftest ebox-image-prepare-rejects-invalid-protocol-inputs ()
  (should-error (ebox-image-prepare '(image :type xpm :data "bad") 0 1))
  (should-error (ebox-image-prepare '(image :type xpm :data "bad") 1 1 :adapter 'unknown))
  (should-error (ebox-image-prepare '(not-image) 1 1)))

(ert-deftest ebox-file-read-form-accepts-exactly-one-expression ()
  (should (equal (ebox-file-read-form "(box \"Hi\")") '(box "Hi")))
  (should-error (ebox-file-read-form "") :type 'user-error)
  (should-error (ebox-file-read-form "(box \"A\") (box \"B\")") :type 'user-error))

(ert-deftest ebox-file-evaluate-form-returns-renderable-dsl ()
  (let ((dsl (ebox-file-evaluate-form ''(box :width (ch 2) "Hi"))))
    (should (equal dsl '(box :width '(ch 2) "Hi")))
    (should (equal (ebox-test-render-text (ebox-build dsl)) "Hi"))))

(ert-deftest ebox-file-evaluate-buffer-reads-current-buffer-source ()
  (with-temp-buffer
    (insert "'(box :width (ch 2) \"OK\")")
    (should (equal (ebox-file-evaluate-buffer (current-buffer))
                   '(box :width '(ch 2) "OK")))))
;
(ert-deftest ebox-file-load-companion-prefers-only-newer-bytecode ()
  "A companion loads its source unless its bytecode is newer."
  (let* ((directory (make-temp-file "ebox-companion" t))
         (base (expand-file-name "demo" directory)))
    (unwind-protect
        (progn
          (with-temp-file (concat base ".el")
            (insert ";;; -*- lexical-binding: t; -*-\n"
                    "(put 'ebox-file-load-companion 'test-origin (file-name-extension load-file-name))\n"))
          (put 'ebox-file-load-companion 'test-origin nil)
          (ebox-file-load-companion (concat base ".ebox"))
          (should (equal (get 'ebox-file-load-companion 'test-origin) "el"))
          (byte-compile-file (concat base ".el"))
          (set-file-times (concat base ".el") (time-subtract nil 60))
          (put 'ebox-file-load-companion 'test-origin nil)
          (ebox-file-load-companion (concat base ".ebox"))
          (should (equal (get 'ebox-file-load-companion 'test-origin) "elc"))
          (set-file-times (concat base ".el") (time-add nil 60))
          (put 'ebox-file-load-companion 'test-origin nil)
          (ebox-file-load-companion (concat base ".ebox"))
          (should (equal (get 'ebox-file-load-companion 'test-origin) "el")))
      (put 'ebox-file-load-companion 'test-origin nil)
      (delete-directory directory t))))

(ert-deftest ebox-image-canvas-preparation-ignores-its-live-pixels ()
  "A canvas keeps one preparation while its producer rewrites pixels.
The payload is a live buffer, so the cached identity must not compare it:
two preparations with the same :id and size are the same image."
  (let* ((first (ebox-image-prepare
                 '(image :type canvas :id canvas-live-test :data "aaaa"
                         :data-width 4 :data-height 1 :scale 1)
                 2 1 :adapter 'placeholder))
         (second (ebox-image-prepare
                  '(image :type canvas :id canvas-live-test :data "bbbb"
                          :data-width 4 :data-height 1 :scale 1)
                  2 1 :adapter 'placeholder)))
    (should (eq first second))))

(ert-deftest ebox-image-canvas-preparation-distinguishes-ids ()
  "Two canvases with different ids stay distinct preparations."
  (let ((left (ebox-image-prepare
               '(image :type canvas :id canvas-left-test :data "aaaa"
                       :data-width 4 :data-height 1 :scale 1)
               2 1 :adapter 'placeholder))
        (right (ebox-image-prepare
                '(image :type canvas :id canvas-right-test :data "aaaa"
                        :data-width 4 :data-height 1 :scale 1)
                2 1 :adapter 'placeholder)))
    (should-not (eq left right))))

;;; ebox-image-file-tests.el ends here
