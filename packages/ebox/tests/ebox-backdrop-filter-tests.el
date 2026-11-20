;;; -*- lexical-binding: t; -*-
;;; ebox-backdrop-filter-tests.el --- Ebox backdrop filter tests

;; Public behaviour of the `:backdrop-filter' style property: an overlay that
;; declares it keeps the covered cells and dims their colors.

(require 'ebox-test-support)

(ert-deftest ebox-backdrop-filter-keeps-text-and-dims-colors ()
  "A filtered overlay keeps covered text visible with dimmed colors."
  (let* ((ebox-viewport-width (* 12 (frame-char-width)))
         (ebox-viewport-height 1)
         (rendered
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#FFFFFF" :background-color "#101820"
                         "Hello")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (brightness 0.5))))))
    (should (equal (substring-no-properties rendered 0 5) "Hello"))
    (should (equal (get-text-property 0 'face rendered)
                   '(:foreground "#800080008000" :background "#08080C0C1010")))))

(ert-deftest ebox-backdrop-filter-dims-nested-inherited-faces ()
  "Nested native faces keep their effective palette when filtered."
  (let* ((ebox-viewport-width 12)
         (ebox-viewport-height 1)
         (text (propertize "ink" 'face '((:foreground "#E0C0A0")
                                        ((:foreground "#FFFFFF")
                                         (:background "#204060")))))
         (rendered (ebox-render
                    (list 'column :width '(px 12) :height '(lh 1)
                          (ebox-text-create text)
                          '(box :position absolute :layer root :left (px 0) :top (lh 0)
                                :width (% 100) :height (% 100)
                                :backdrop-filter (brightness 0.5))))))
    (should (equal (get-text-property 0 'face rendered)
                   '(:foreground "#707060605050" :background "#101020203030")))))

(ert-deftest ebox-backdrop-filter-keeps-image-content-visible ()
  "A filtered overlay does not blank the image cells behind it."
  (let* ((ebox-viewport-width (* 6 (frame-char-width)))
         (ebox-viewport-height 1)
         (image (ebox-node-create
                 'image (list :image (ebox-image-prepare
                                      '(image :type xpm :data "bad")
                                      2 1 :adapter 'placeholder))))
         (rendered
          (ebox-render
           (list 'column :width '(% 100) :height '(% 100)
                 image
                 '(box :position absolute :layer root
                       :left (px 0) :top (lh 0)
                       :width (% 100) :height (% 100)
                       :backdrop-filter (brightness 0.5))))))
    (should (equal (substring-no-properties rendered 0 2) ".."))))

(ert-deftest ebox-backdrop-filter-partial-paint-preserves-source-and-input ()
  "Partial filtered paint keeps source faces and separates covering input."
  (let* ((under-map (ebox-keymap-create :activate #'ignore))
         (cover-map (ebox-keymap-create :activate #'ignore))
         (cover (ebox-build
                 (list 'box :position 'absolute :layer 'root
                       :left '(ch 2) :top '(lh 0) :width '(ch 8) :height '(lh 1)
                       :color "#00FF00" :keymap cover-map :help-echo "Cover"
                       :backdrop-filter '(brightness 0.5) "XX  YY"))))
    (ebox-test-with-mounted
        (buffer root
                (list 'column :width '(ch 12) :height '(lh 1)
                      (list 'box :width '(ch 12) :height '(lh 1)
                            :color "#FFFFFF" :background-color "#204060"
                            :keymap under-map :help-echo "Source" "ABCDEFGHIJKL")))
      (let ((before (buffer-substring-no-properties (point-min) (point-max)))
            (face (copy-tree (get-text-property 5 'face))))
        (dolist (amount '(0.5 1 0.75))
          (ebox-node-put cover :backdrop-filter (list 'brightness amount))
          (ebox-node-insert root cover)
          (let ((text (buffer-substring-no-properties 1 13))
                (owned (eq (get-text-property 5 'keymap) cover-map)))
            (should (equal text "ABXXEFYYIJKL"))
            (should owned))
          (should (equal (get-text-property 5 'help-echo) "Cover"))
          (should (equal (get-text-property 1 'face) face))
          (ebox-node-set-text (ebox-node-child cover 0) "X   Y")
          (let ((text (buffer-substring-no-properties 1 13)))
            (should (equal text "ABXDEFYHIJKL")))
          (ebox-node-remove cover)
          (let ((text (buffer-substring-no-properties (point-min) (point-max)))
                (owned (eq (get-text-property 5 'keymap) under-map)))
            (should (equal text before))
            (should owned))
          (should (equal (get-text-property 5 'face) face))
          (should (equal (get-text-property 5 'help-echo) "Source"))
          (ebox-node-set-text (ebox-node-child cover 0) "XX  YY"))))))

(ert-deftest ebox-backdrop-filter-keeps-overlay-content-crisp ()
  "Only the pixels behind an overlay dim; its own content stays unchanged."
  (let* ((ebox-viewport-width (* 8 (frame-char-width)))
         (ebox-viewport-height 1)
         (rendered
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#FFFFFF" :background-color "#101820"
                         "Hello")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (ch 4) :height (lh 1)
                         :color "#00FF00"
                         :backdrop-filter (brightness 0.5)
                         "TOP")))))
    (should (equal (substring-no-properties rendered 0 5) "TOPlo"))
    (should (equal (get-text-property 0 'face rendered)
                   '(:foreground "#00FF00")))
    (should (equal (get-text-property 3 'face rendered)
                   '(:foreground "#800080008000" :background "#08080C0C1010")))
    (should (equal (get-text-property 4 'face rendered)
                   '((:foreground "#FFFFFF") (:background "#101820"))))))

(ert-deftest ebox-backdrop-filter-keeps-covered-cells-out-of-flow-hit ()
  "A filtered overlay still owns the cells it covers."
  (ebox-test-with-mounted
      (buffer root
              '(column :width (ch 8) :height (lh 2)
                       (box :id "under" :width (ch 8) :height (lh 1)
                            "Hello")
                       (box :id "veil" :position absolute :layer root
                            :left (px 0) :top (lh 0)
                            :width (% 100) :height (% 100)
                            :backdrop-filter (brightness 0.5))))
    (should (ebox-test-buffer-matches-render-p root buffer))
    (should (null (ebox-node-bounds (ebox-node-child root 0))))
    (should (ebox-node-bounds (ebox-node-child root 1)))))

(ert-deftest ebox-backdrop-filter-keeps-overlay-input-and-blocks-underlay ()
  "Visible dimmed text uses the covering overlay's native input, never its source."
  (dolist (interactive '(t nil))
    (let* ((under-count 0) (over-count 0)
           (under-map (ebox-keymap-create :activate (lambda () (cl-incf under-count))))
           (over-map (and interactive
                          (ebox-keymap-create :activate (lambda () (cl-incf over-count))))))
      (ebox-test-with-mounted
          (buffer root
                  (list 'column :width '(ch 20) :height '(lh 3)
                        (list 'box :width '(ch 20) :height '(lh 1)
                              :keymap under-map :help-echo "Underlay" :pointer 'hand
                              "Clickable background")
                        (list 'box :position 'absolute :layer 'root
                              :left '(px 0) :top '(lh 0)
                              :width '(% 100) :height '(% 100)
                              :backdrop-filter '(brightness 0.5)
                              :keymap over-map :help-echo "Overlay" :pointer 'arrow)))
        (let ((node (ebox-node-at (point-min) buffer))
              (overlay (ebox-node-child root 1))
              (map (get-text-property (point-min) 'keymap)))
          (let ((owns-hit (eq node overlay))) (should owns-hit))
          (should (equal (get-text-property (point-min) 'help-echo) "Overlay"))
          (should (eq (get-text-property (point-min) 'pointer) 'arrow))
          (when interactive
            (let ((command (lookup-key map [mouse-1]))
                  (last-input-event (list 'mouse-1 (list (selected-window) 1 '(0 . 0) 0))))
              (should (commandp command))
              (call-interactively command)))
          (should (= under-count 0))
          (should (= over-count (if interactive 1 0)))
          (let ((matches (ebox-test-buffer-matches-render-p root buffer)))
            (should matches)))))))

(ert-deftest ebox-backdrop-filter-brightness-range-and-invalid-values ()
  "Brightness 1 keeps colors, higher values clamp, and other filters\nare dropped instead of dimming."
  (let* ((ebox-viewport-width (* 6 (frame-char-width)))
         (ebox-viewport-height 1)
         (identity
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#FFFFFF" :background-color "#101820"
                         "Hi")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (brightness 1)))))
         (raised
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1)
                         :color "#808080" "Hi")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (brightness 2)))))
         (unsupported
          (ebox-render
           '(column :width (% 100) :height (% 100)
                    (box :width (% 100) :height (lh 1) "Hi")
                    (box :position absolute :layer root
                         :left (px 0) :top (lh 0)
                         :width (% 100) :height (% 100)
                         :backdrop-filter (blur 2))))))
    (should (equal (get-text-property 0 'face identity)
                   '((:foreground "#FFFFFF") (:background "#101820"))))
    (should (equal (plist-get (get-text-property 0 'face raised) :foreground)
                   "#FFFFFFFFFFFF"))
    (should (equal (substring-no-properties unsupported) " "))))

(ert-deftest ebox-backdrop-filter-reattaching-the-same-overlay-repaints ()
  "A previously laid out overlay paints again at its unchanged coordinates."
  (let ((veil (ebox-build '(box :position absolute :layer root :left (px 0) :top (lh 0)
                                :width (% 100) :height (% 100)
                                :backdrop-filter (brightness 0.5)))))
    (ebox-test-with-mounted
        (buffer root '(column :width (ch 12) :height (lh 3)
                              (box :color "#FFFFFF" "visible")))
      (dotimes (_ 3)
        (ebox-node-insert root veil)
        (should (equal (plist-get (get-text-property 1 'face) :foreground)
                       "#800080008000"))
        (ebox-node-remove veil)
        (should (equal (plist-get (get-text-property 1 'face) :foreground)
                       "#FFFFFF"))))))

(defun ebox-test-backdrop-images (string)
  "Return native image descriptors painted in STRING, in run order."
  (let ((position 0) images)
    (while (< position (length string))
      (let* ((display (get-text-property position 'display string))
             (image (if (eq (car-safe display) 'image) display
                      (and (consp (car-safe display)) (assq 'image display)))))
        (when image (push image images))
        (setq position (next-single-property-change
                        position 'display string (length string)))))
    (nreverse images)))

(ert-deftest ebox-backdrop-filter-dims-prepared-raster-and-restores-slices ()
  "Prepared pixels dim without I/O, resize, source mutation or lost insets."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (let* ((file (make-temp-file "ebox-backdrop-" nil ".png"))
         (bytes (base64-decode-string
                 (concat "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAHElEQVR4nGM4"
                         "EaDxX2NLRYNIwB2GlIoF/xnQBQAFew+dXjXBbAAAAABJRU5ErkJggg==")))
         prepared)
    (unwind-protect
        (let ((coding-system-for-write 'no-conversion))
          (with-temp-file file (set-buffer-multibyte nil) (insert bytes))
          (setq prepared (ebox-image-prepare file 12 3 :inset '(1 . 2))))
      (delete-file file))
    (should (eq (plist-get (ebox-image-info prepared) :adapter) 'graphics))
    (let* ((source-content (ebox-image-content prepared))
           (image (ebox-node-create 'image (list :image prepared)))
           (veil (ebox-build '(box :position absolute :layer root :z-index 1
                                  :left (px 0) :top (lh 0)
                                  :width (% 100) :height (% 100)
                                  :backdrop-filter (brightness 0.5)))))
      (ebox-test-with-mounted
          (buffer root (ebox-node-create 'column '(:width (ch 12) :height (lh 3)
                                                  :background-color "#E0C0A0")
                                         (list image)))
        (let* ((before (ebox-test-buffer-string buffer))
               (geometry (ebox-node-geometry image))
               (original (ebox-test-backdrop-images before)))
          (ebox-node-insert root veil)
          (let* ((paint (ebox-test-buffer-string buffer))
                 (dimmed (ebox-test-backdrop-images paint))
                 (same-geometry (equal geometry (ebox-node-geometry image))))
            (should same-geometry)
            (should (= (length dimmed) (length original)))
            (should-not (equal dimmed original))
            (should (equal (mapcar (lambda (spec) (image-size spec t)) dimmed)
                           (mapcar (lambda (spec) (image-size spec t)) original)))
            (let ((position 0))
              (while (< position (length before))
                (let ((old (get-text-property position 'display before))
                      (new (get-text-property position 'display paint)))
                  ;; Native slice/raise geometry stays byte-for-byte the same.
                  (when (and (consp (car-safe old)) (assq 'image old))
                    (should (equal (butlast old) (butlast new)))))
                (cl-incf position)))
            (ebox-node-remove veil)
            (let* ((after (ebox-test-buffer-string buffer))
                   (restored (equal original (ebox-test-backdrop-images after))))
              (should restored)
              (should (equal (substring-no-properties before)
                             (substring-no-properties after)))
              ;; Newline faces can be filled after the first canvas remap;
              ;; image rows must recover their exact native displays and faces.
              (dotimes (position (length before))
                (unless (= (aref before position) ?\n)
                  (should (equal (get-text-property position 'display before)
                                 (get-text-property position 'display after)))
                  (should (equal (get-text-property position 'face before)
                                 (get-text-property position 'face after))))))
            (ebox-node-insert root veil)
            (let ((reused (eq (car dimmed)
                              (car (ebox-test-backdrop-images
                                    (ebox-test-buffer-string buffer))))))
              (should reused)))))
      (let ((unchanged (equal-including-properties
                        source-content (ebox-image-content prepared))))
        (should unchanged)))))

(ert-deftest ebox-backdrop-filter-dims-native-display-runs-and-blocks-input ()
  "Raw SVG runs and cropped slices dim, while only the covering node activates."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (let* ((image (create-image
                 (concat "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='16'>"
                         "<rect width='120' height='16' fill='#80C0E0' fill-opacity='.5'/></svg>")
                 'svg t :scale 1 :ascent 80 :margin 0))
         (calls 0)
         (cover-calls 0)
         (under-map (ebox-keymap-create :activate (lambda () (cl-incf calls))))
         (cover-map (ebox-keymap-create :activate (lambda () (cl-incf cover-calls))))
         (text (concat (propertize "a" 'display image)
                       (propertize "b" 'display (list '(raise 0.1) '(slice 10 0 40 16) image))
                       "text"))
         (veil (ebox-build
                (list 'box :position 'absolute :layer 'root :left '(px 20) :top '(lh 0)
                      :width '(px 120) :height '(lh 1) :z-index 1
                      :keymap cover-map :tab-index 0 :help-echo "shade" :pointer 'arrow
                      :backdrop-filter '(brightness 0.5)))))
    (ebox-test-with-mounted
        (buffer root (ebox-node-create
                      'column '(:width (px 200) :height (lh 1) :background-color "#F0F0F0")
                      (list (ebox-node-create
                             'box (list :keymap under-map :tab-index 0
                                        :help-echo "under" :pointer 'hand)
                             (list (ebox-text-create text))))))
      (ebox-node-insert root veil)
      (let* ((bounds (ebox-node-bounds veil))
             (at (car bounds))
             (display (get-text-property at 'display))
             (painted (assq 'image display))
             (owns (eq veil (ebox-node-at at buffer)))
             (same-size (equal (image-size painted t) (image-size image t))))
        (should owns)
        (should same-size)
        (should-not (equal painted image))
        (should (equal (assq 'slice display) '(slice 20 0 100 1.0)))
        (should (equal (get-text-property at 'help-echo) "shade"))
        (ebox-activate at)
        (should (= calls 0))
        (should (= cover-calls 1))
        (ebox-focus (ebox-node-child root 0) buffer)
        (let ((covered-focused (eq (ebox-focused-node buffer) (ebox-node-child root 0))))
          ;; This partly exposed control remains eligible; a full shade blocks it.
          (should covered-focused))
        (ebox-node-put veil :left '(px 0))
        (ebox-node-put veil :width '(% 100))
        (ebox-focus veil buffer)
        (let ((blocked (condition-case nil
                           (progn (ebox-focus (ebox-node-child root 0) buffer) nil)
                         (user-error t))))
          (should blocked))
        (let ((still-cover (eq (ebox-focused-node buffer) veil))) (should still-cover))))))

(ert-deftest ebox-backdrop-filter-svg-follows-native-current-color ()
  "One reusable currentColor icon keeps distinct native face variants."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (let* ((image (create-image
                 (concat "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'>"
                         "<circle cx='8' cy='8' r='6' fill='currentColor'/></svg>")
                 'svg t :ascent 'center :scale 1))
         (text (ebox-text-create (propertize " " 'display image) '(:color "#FFFFFF")))
         (veil (ebox-build '(box :position absolute :layer root :z-index 1
                                :left (px 0) :top (lh 0) :width (% 100) :height (% 100)
                                :backdrop-filter (brightness 0.5)))))
    (ebox-test-with-mounted
        (buffer _root (ebox-node-create 'column '(:width (px 16) :height (lh 1)
                                                :background-color "#202830") (list text veil)))
      (let ((white (car (ebox-test-backdrop-images (ebox-test-buffer-string)))))
        (ebox-node-put text :color "#4080C0")
        (let* ((blue (car (ebox-test-backdrop-images (ebox-test-buffer-string))))
               (same-size (equal (image-size white t) (image-size blue t))))
          (should same-size)
          (should-not (equal white blue)))
        (ebox-node-put text :color "#FFFFFF")
        (let ((restored (eq white (car (ebox-test-backdrop-images (ebox-test-buffer-string))))))
          (should restored))))))

(ert-deftest ebox-backdrop-filter-image-identity-nesting-theme-and-live-update ()
  "Image variants follow nested filters, live pixels and palette changes."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (let* ((descriptor (lambda (color)
                       (create-image
                        (format (concat "<svg xmlns='http://www.w3.org/2000/svg' width='28' height='16'>"
                                        "<circle cx='14' cy='8' r='7' fill='%s'/></svg>") color)
                        'svg t :scale 1 :ascent 80)))
         (first (funcall descriptor "#FFFFFF"))
         (second (funcall descriptor "#FF8000"))
         (text (ebox-text-create (propertize " " 'display first)))
         (veil (ebox-build '(box :position absolute :layer root :z-index 1
                                :left (px 0) :top (lh 0) :width (% 100) :height (% 100)
                                :backdrop-filter (brightness 1))))
         (nested (ebox-build '(box :position absolute :layer root :z-index 2
                                  :left (px 0) :top (lh 0) :width (% 100) :height (% 100)
                                  :backdrop-filter (brightness 0.5)))))
    (ebox-test-with-mounted
        (buffer root (ebox-node-create 'column '(:width (px 28) :height (lh 1)
                                                :background-color "#F0F0F0") (list text)))
      (ebox-node-insert root veil)
      (let ((identity (eq first (car (ebox-test-backdrop-images (ebox-test-buffer-string))))))
        (should identity))
      (ebox-node-put veil :backdrop-filter '(brightness 0.5))
      (let ((dim (car (ebox-test-backdrop-images (ebox-test-buffer-string)))))
        (should-not (equal dim first))
        (ebox-node-insert root nested)
        (let ((twice (car (ebox-test-backdrop-images (ebox-test-buffer-string)))))
          (should-not (equal twice dim)))
        (ebox-node-remove nested)
        (let ((restored (eq dim (car (ebox-test-backdrop-images (ebox-test-buffer-string))))))
          (should restored))
        (ebox-node-put root :background-color "#202830")
        (let ((dark (car (ebox-test-backdrop-images (ebox-test-buffer-string)))))
          (should-not (equal dark dim)))
        (ebox-node-set-text text (propertize " " 'display second))
        (let ((changed (car (ebox-test-backdrop-images (ebox-test-buffer-string)))))
          (should-not (equal changed dim))
          (should-not (equal changed second)))
        (ebox-node-remove veil)
        (let ((live (eq second (car (ebox-test-backdrop-images (ebox-test-buffer-string))))))
          (should live))))))

(ert-deftest ebox-backdrop-identity-preserves-partially-covered-glyphs ()
  "A transparent hit strip keeps a straddling text glyph and its native input."
  (let ((under-count 0) (over-count 0))
    (ebox-test-with-mounted
        (buffer root
                (list 'column :width '(ch 12) :height '(lh 1)
                      (list 'box :width 'stretch :height '(lh 1)
                            :keymap (ebox-keymap-create :activate
                                                       (lambda () (cl-incf under-count)))
                            :pointer 'hand "A界B中C")
                      (list 'box :position 'absolute :layer 'root
                            :left '(ch 2) :top '(lh 0) :width '(ch 1) :height '(lh 1)
                            :backdrop-filter '(brightness 1)
                            :keymap (ebox-keymap-create :activate
                                                       (lambda () (cl-incf over-count)))
                            :pointer 'hdrag)))
      (let ((strip (ebox-node-child root 1)))
        (dolist (sample '((2 . "界") (1 . "界") (5 . "中") (4 . "中") (2 . "界")))
          (ebox-node-put strip :left (list 'ch (car sample)))
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-prefix-p "A界B中C" text)))
          (goto-char (point-min))
          (search-forward (cdr sample))
          (backward-char)
          (let* ((position (point))
                 (owner (ebox-node-at position buffer))
                 (map (get-text-property position 'keymap))
                 (command (lookup-key map [mouse-1]))
                 (last-input-event (list 'mouse-1
                                         (list (selected-window) position '(0 . 0) 0))))
            (let ((owned (eq owner strip))) (should owned))
            (should (eq (get-text-property position 'pointer) 'hdrag))
            (should (commandp command))
            (call-interactively command)))
        (should (= over-count 5))
        (should (= under-count 0))
        (ebox-node-put strip :visibility 'hidden)
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          (should (string-prefix-p "A界B中C" text)))
        (goto-char (point-min))
        (search-forward "界")
        (should (eq (get-text-property (1- (point)) 'pointer) 'hand))))))

(provide 'ebox-backdrop-filter-tests)
;;; ebox-backdrop-filter-tests.el ends here
