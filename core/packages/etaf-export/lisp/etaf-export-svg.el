;;; etaf-export-svg.el --- Smart pagination and vector SVG emitter -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Converts an `etaf-export-snapshot' into one or more standalone vector SVG
;; pages (ISO A4, US Letter, or continuous single-page) ready for direct SVG
;; export or multi-page vector PDF compilation via `rsvg-convert -f pdf'.
;; Inline SVGs (Mermaid diagrams, MathJax equations, Ebox rounded borders) are
;; namespace-scoped and embedded as nested <svg> elements so they remain
;; infinite-resolution vectors with selectable text inside the exported PDF.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'etaf-export-snapshot)

(defconst etaf-export--page-sizes
  '((a4     . (595.28 . 841.89))
    (letter . (612.00 . 792.00)))
  "Standard page dimensions in PDF points (1 pt = 1/72 inch).")

(defun etaf-export--xml-escape (str)
  "Escape STR for safe XML text or attribute emission."
  (let ((s (or str "")))
    (setq s (replace-regexp-in-string "[\000-\010\013\014\016-\037]" "" s))
    (setq s (replace-regexp-in-string "&" "&amp;" s t t))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (setq s (replace-regexp-in-string ">" "&gt;" s t t))
    (setq s (replace-regexp-in-string "\"" "&quot;" s t t))
    (setq s (replace-regexp-in-string "'" "&#39;" s t t))
    s))

;;;; Inline Vector SVG Embedding with Unique ID Scoping

(defun etaf-export--extract-xml-attr (attrs name)
  "Return string value of XML attribute NAME in ATTRS header string, or nil."
  (let ((case-fold-search nil)
        (re (format "\\b%s[ \t\n]*=[ \t\n]*\\(?:\"\\([^\"]*\\)\"\\|'\\([^']*\\)'\\)"
                    (regexp-quote name))))
    (when (string-match re attrs)
      (or (match-string 1 attrs) (match-string 2 attrs)))))

(defun etaf-export--parse-num-attr (val)
  "Extract leading positive float from SVG length string VAL, or nil."
  (when (and (stringp val) (string-match "\\`[ \t]*\\([0-9]+\\(?:\\.[0-9]+\\)?\\)" val))
    (let ((n (string-to-number (match-string 1 val))))
      (when (> n 0) (float n)))))

(defun etaf-export--scope-svg-ids (body prefix)
  "Prefix all `id' definitions and local fragment references in SVG BODY."
  (let ((ids (make-hash-table :test #'equal))
        (pos 0))
    (while (string-match "\\bid[ \t]*=[ \t]*\\(?:\"\\([^\"]+\\)\"\\|'\\([^']+\\)'\\)" body pos)
      (let ((id (or (match-string 1 body) (match-string 2 body))))
        (puthash id t ids))
      (setq pos (match-end 0)))
    (if (zerop (hash-table-count ids))
        body
      (let ((out body))
        (setq out
              (replace-regexp-in-string
               "\\bid\\([ \t]*=[ \t]*\\)\\([\"']\\)\\([^\"']+\\)\\2"
               (lambda (m)
                 (let ((eqs (match-string 1 m))
                       (q (match-string 2 m))
                       (id (match-string 3 m)))
                   (if (gethash id ids)
                       (concat "id" eqs q prefix id q)
                     m)))
               out t t))
        (setq out
              (replace-regexp-in-string
               "url([ \t]*['\"]?#\\([^)'\" \t]+\\)['\"]?[ \t]*)"
               (lambda (m)
                 (let ((id (match-string 1 m)))
                   (if (gethash id ids)
                       (format "url(#%s%s)" prefix id)
                     m)))
               out t t))
        (setq out
              (replace-regexp-in-string
               "\\(\\(?:xlink:\\)?href[ \t]*=[ \t]*\\)\\([\"']\\)#\\([^\"']+\\)\\2"
               (lambda (m)
                 (let ((attr (match-string 1 m))
                       (q (match-string 2 m))
                       (id (match-string 3 m)))
                   (if (gethash id ids)
                       (concat attr q "#" prefix id q)
                     m)))
               out t t))
        out))))

(defun etaf-export--find-last-svg-close (svg-text start)
  "Return index of the last `</svg>' (case-insensitive) in SVG-TEXT from START."
  (let ((pos nil)
        (from start))
    (while-let ((hit (string-search "</svg>" svg-text from)))
      (setq pos hit
            from (+ hit 6)))
    (or pos
        (let ((case-fold-search t)
              (p start)
              (last nil))
          (while (string-match "</svg>" svg-text p)
            (setq last (match-beginning 0)
                  p (match-end 0)))
          last))))

(defun etaf-export--split-svg-root (svg-text)
  "Return `(ATTRS . INNER)' for outermost `<svg ...>...</svg>' in SVG-TEXT, or nil.
Uses linear substring search without backtracking regexps so arbitrarily large
SVGs never trigger `Stack overflow in regexp matcher'."
  (when (stringp svg-text)
    (let ((case-fold-search t))
      (when-let* ((open-start (string-match "<svg\\(?:[ \t\n\r]\\|>\\)" svg-text))
                  (open-end (string-search ">" svg-text open-start))
                  ((> open-end open-start))
                  ((/= (aref svg-text (1- open-end)) ?/))
                  (close-pos (etaf-export--find-last-svg-close svg-text (1+ open-end))))
        (cons (substring svg-text (+ open-start 4) open-end)
              (substring svg-text (1+ open-end) close-pos))))))

(defun etaf-export--embed-inline-svg (svg-bytes x y w h prefix theme orig-bg &optional fallback-color)
  "Build a nested `<svg>' element embedding SVG-BYTES at (X Y W H).
When the inner `<svg>' omits an explicit `color' attribute, FALLBACK-COLOR is
forwarded so icons using `currentColor' inherit the Emacs face foreground."
  (let* ((raw (if (multibyte-string-p svg-bytes)
                  svg-bytes
                (decode-coding-string svg-bytes 'utf-8 t)))
         (clean (if (eq theme 'light)
                    (etaf-export--remap-svg-light raw orig-bg)
                  raw))
         (parts (etaf-export--split-svg-root clean)))
    (if parts
        (let* ((attrs (car parts))
               (inner (cdr parts))
               (vb (etaf-export--extract-xml-attr attrs "viewBox"))
               (ow (etaf-export--parse-num-attr (etaf-export--extract-xml-attr attrs "width")))
               (oh (etaf-export--parse-num-attr (etaf-export--extract-xml-attr attrs "height")))
               (eff-vb (or vb (format "0 0 %.2f %.2f" (or ow w) (or oh h))))
               (style (etaf-export--extract-xml-attr attrs "style"))
               (fill (etaf-export--extract-xml-attr attrs "fill"))
               (stroke (etaf-export--extract-xml-attr attrs "stroke"))
               (color (or (etaf-export--extract-xml-attr attrs "color")
                          fallback-color))
               (preserve (or (etaf-export--extract-xml-attr attrs "preserveAspectRatio")
                             "xMidYMid meet"))
               (scoped (etaf-export--scope-svg-ids inner prefix))
               (extra (concat
                       (when style (format " style=\"%s\"" (etaf-export--xml-escape style)))
                       (when fill (format " fill=\"%s\"" (etaf-export--xml-escape fill)))
                       (when stroke (format " stroke=\"%s\"" (etaf-export--xml-escape stroke)))
                       (when color (format " color=\"%s\"" (etaf-export--xml-escape color))))))
          (format "<svg x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" viewBox=\"%s\" preserveAspectRatio=\"%s\" overflow=\"hidden\"%s>%s</svg>"
                  x y w h (etaf-export--xml-escape eff-vb)
                  (etaf-export--xml-escape preserve) extra scoped))
      ;; Fallback to data URI when input is not a standard <svg> wrapper
      (format "<image x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" preserveAspectRatio=\"xMidYMid meet\" href=\"data:image/svg+xml;base64,%s\"/>"
              x y w h (base64-encode-string
                       (if (multibyte-string-p clean)
                           (encode-coding-string clean 'utf-8)
                         clean)
                       t)))))

(defun etaf-export--embed-raster (type bytes x y w h)
  "Build an `<image>' element with base64 data URI for raster TYPE and BYTES."
  (let* ((mime (pcase type
                 ('png "image/png")
                 ('jpeg "image/jpeg")
                 ('gif "image/gif")
                 ('webp "image/webp")
                 (_ "image/png")))
         (raw (if (multibyte-string-p bytes)
                  (encode-coding-string bytes 'binary)
                bytes)))
    (format "<image x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" preserveAspectRatio=\"xMidYMid meet\" href=\"data:%s;base64,%s\"/>"
            x y w h mime (base64-encode-string raw t))))

;;;; Smart Pagination

(defun etaf-export--paginate (snapshot page-mode margin page-numbers)
  "Partition SNAPSHOT lines into page specifications for PAGE-MODE.
Return plist (:page-w :page-h :margin-x :margin-y :scale :offset-x :pages)
where each page is (:index N :start-row R0 :end-row R1 :y0 Y0 :y1 Y1 :page-h H)."
  (let* ((lines (plist-get snapshot :lines))
         (n-lines (length lines))
         (images (plist-get snapshot :images))
         (content-w (plist-get snapshot :content-width))
         (content-h (plist-get snapshot :content-height))
         (spec (alist-get page-mode etaf-export--page-sizes))
         (paginated (and (not (eq page-mode 'single)) spec))
         (margin-x (float (or margin (if paginated 28.0 24.0))))
         (margin-y (float (or margin (if paginated 30.0 24.0))))
         (page-w (if paginated (car spec) (max 595.28 (+ content-w (* 2.0 margin-x)))))
         (printable-w (max 120.0 (- page-w (* 2.0 margin-x))))
         (scale (min 1.0 (/ printable-w (max 1.0 content-w))))
         (scaled-w (* content-w scale))
         (offset-x (+ margin-x (/ (max 0.0 (- printable-w scaled-w)) 2.0))))
    (cond
     ((zerop n-lines)
      (let ((h (if paginated (cdr spec) (+ (* 2.0 margin-y) 60.0))))
        (list :page-w page-w :page-h h :margin-x margin-x :margin-y margin-y
              :scale scale :offset-x offset-x
              :pages (list (list :index 1 :start-row 0 :end-row 0 :y0 0.0 :y1 0.0 :page-h h)))))
     ((not paginated)
      (let ((h (+ (* 2.0 margin-y) (* content-h scale))))
        (list :page-w page-w :page-h h :margin-x margin-x :margin-y margin-y
              :scale scale :offset-x offset-x
              :pages (list (list :index 1
                                 :start-row 0
                                 :end-row n-lines
                                 :y0 0.0
                                 :y1 content-h
                                 :page-h h)))))
     (t
      (let* ((page-h (cdr spec))
             (footer-h (if page-numbers 18.0 0.0))
             (avail-content-h (/ (max 100.0 (- page-h (* 2.0 margin-y) footer-h)) scale))
             (line-vec (vconcat lines))
             (pages nil)
             (cur 0)
             (page-no 0))
        (while (< cur n-lines)
          (let* ((y0 (plist-get (aref line-vec cur) :y))
                 (end cur))
            ;; Greedily fill rows that fit within avail-content-h
            (while (and (< end n-lines)
                        (let* ((ln (aref line-vec end))
                               (y-bot (+ (plist-get ln :y) (plist-get ln :height))))
                          (or (= end cur) (<= (- y-bot y0) avail-content-h))))
              (setq end (1+ end)))
            ;; Smart break adjustments only when more content remains
            (when (< end n-lines)
              ;; 1. Keep stitched images/diagrams unbroken when they fit on a fresh page
              (dolist (img images)
                (let ((sr (plist-get img :start-row))
                      (er (plist-get img :end-row))
                      (ih (plist-get img :h)))
                  (when (and (< sr end) (>= er end) (> sr cur)
                             (<= ih (* avail-content-h 0.95)))
                    (setq end sr))))
              ;; 2. Prefer breaking on a blank canvas row within the last 18% of page
              (let* ((lookback-min (+ cur (max 1 (floor (* (- end cur) 0.80)))))
                     (best-blank nil))
                (cl-loop for idx downfrom (1- end) to lookback-min
                         for ln = (aref line-vec idx)
                         when (and (not (plist-get ln :has-ink))
                                   (not (cl-some (lambda (img)
                                                   (and (<= (plist-get img :start-row) idx)
                                                        (<= idx (plist-get img :end-row))))
                                                 images)))
                         do (setq best-blank (1+ idx))
                         and return nil)
                (when (and best-blank (> best-blank cur))
                  (setq end best-blank)))
              ;; 3. Never leave a heading (+ its underline/blank gap) orphaned at page bottom
              (let ((min-keep (+ cur (max 1 (floor (* (- end cur) 0.45))))))
                (when (> end min-keep)
                  (let ((probe (1- end))
                        (heading-row nil)
                        (trailing-non-heading 0))
                    (while (and (>= probe (max min-keep (- end 8))) (null heading-row))
                      (let ((ln (aref line-vec probe)))
                        (cond
                         ((> (plist-get ln :max-scale) 1.15)
                          (setq heading-row probe))
                         ((plist-get ln :has-ink)
                          (setq trailing-non-heading (1+ trailing-non-heading)))))
                      (setq probe (1- probe)))
                    (when (and heading-row (<= trailing-non-heading 1) (> heading-row min-keep))
                      (setq end heading-row))))))
            (setq end (max (1+ cur) end))
            (let* ((last-ln (aref line-vec (1- end)))
                   (y1 (+ (plist-get last-ln :y) (plist-get last-ln :height))))
              (setq page-no (1+ page-no))
              (push (list :index page-no
                          :start-row cur
                          :end-row end
                          :y0 y0
                          :y1 y1
                          :page-h page-h)
                    pages))
            ;; Skip leading blank canvas lines at top of next page
            (setq cur end)
            (while (and (< cur n-lines)
                        (not (plist-get (aref line-vec cur) :has-ink)))
              (setq cur (1+ cur)))))
        (list :page-w page-w :page-h page-h :margin-x margin-x :margin-y margin-y
              :scale scale :offset-x offset-x
              :pages (nreverse pages)))))))

;;;; SVG Page Emission

(defun etaf-export--wave-path (x y width)
  "Return SVG path data for a subtle wavy underline across (X, Y, WIDTH)."
  (let ((step 3.5)
        (cx x)
        (up t)
        (parts (list (format "M%.2f %.2f" x y))))
    (while (< cx (+ x width))
      (let* ((nx (min (+ x width) (+ cx step)))
             (mx (/ (+ cx nx) 2.0))
             (cy (if up (- y 1.4) (+ y 1.4))))
        (push (format "Q%.2f %.2f %.2f %.2f" mx cy nx y) parts)
        (setq cx nx up (not up))))
    (mapconcat #'identity (nreverse parts) " ")))

(defun etaf-export--render-page-svg (snapshot layout page total-pages page-numbers)
  "Render one standalone vector SVG string for PAGE of SNAPSHOT under LAYOUT."
  (let* ((page-w (plist-get layout :page-w))
         (page-h (plist-get page :page-h))
         (margin-y (plist-get layout :margin-y))
         (scale (plist-get layout :scale))
         (offset-x (plist-get layout :offset-x))
         (min-x (plist-get snapshot :min-x))
         (content-w (plist-get snapshot :content-width))
         (canvas-bg (plist-get snapshot :bg))
         (orig-bg (plist-get snapshot :orig-bg))
         (canvas-fg (plist-get snapshot :fg))
         (theme (plist-get snapshot :theme))
         (metrics (plist-get snapshot :metrics))
         (base-lh (plist-get metrics :lh))
         (base-fs (plist-get metrics :font-size))
         (base-ascent (plist-get metrics :ascent))
         (font-family (plist-get metrics :font-family))
         (lines (vconcat (plist-get snapshot :lines)))
         (images (plist-get snapshot :images))
         (r0 (plist-get page :start-row))
         (r1 (plist-get page :end-row))
         (y0 (plist-get page :y0))
         (y1 (plist-get page :y1))
         (page-idx (plist-get page :index))
         (bg-elems nil)
         (dec-elems nil)
         (img-elems nil)
         (txt-elems nil)
         (svg-seq 0))
    ;; 1. Walk rows on this page
    (cl-loop for idx from r0 below r1
             for line = (aref lines idx)
             for ly = (- (plist-get line :y) y0)
             for lh = (plist-get line :height)
             do
             ;; Optional extended line background/rules
             (when-let* ((ext (plist-get line :extend)))
               (let ((ebg (plist-get ext :bg))
                     (eol (plist-get ext :overline))
                     (eul (plist-get ext :underline))
                     (rx (- (plist-get line :width) min-x)))
                 (when (< rx content-w)
                   (let ((ew (- content-w (max 0.0 rx)))
                         (ex (max 0.0 rx)))
                     (when (and ebg (not (equal ebg canvas-bg)))
                       (push (format "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" fill=\"%s\"/>"
                                     ex ly (+ ew 0.4) (+ lh 0.35) ebg)
                             bg-elems))
                     (when eol
                       (push (format "<line x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" stroke=\"%s\" stroke-width=\"1\"/>"
                                     ex (+ ly 0.5) (+ ex ew) (+ ly 0.5) eol)
                             dec-elems))
                     (when eul
                       (push (format "<line x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" stroke=\"%s\" stroke-width=\"1\"/>"
                                     ex (- (+ ly lh) 0.5) (+ ex ew) (- (+ ly lh) 0.5) eul)
                             dec-elems))))))
             ;; Coalesce adjacent background rects on the same row to eliminate seams
             (let ((run-bg-color nil)
                   (run-bg-x 0.0)
                   (run-bg-w 0.0))
               (cl-labels ((flush-bg ()
                             (when (and run-bg-color (> run-bg-w 0.0))
                               (push (format "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" fill=\"%s\"/>"
                                             run-bg-x ly (+ run-bg-w 0.35) (+ lh 0.35) run-bg-color)
                                     bg-elems))
                             (setq run-bg-color nil run-bg-w 0.0)))
                 (dolist (run (plist-get line :runs))
                   (let* ((kind (plist-get run :kind))
                          (rx (- (plist-get run :x) min-x))
                          (rw (plist-get run :w))
                          (style (plist-get run :style))
                          (rbg (plist-get style :bg)))
                     (if (and rbg (not (equal rbg canvas-bg)) (> rw 0.0))
                         (if (and (equal rbg run-bg-color)
                                  (<= (abs (- rx (+ run-bg-x run-bg-w))) 0.8))
                             (setq run-bg-w (- (+ rx rw) run-bg-x))
                           (flush-bg)
                           (setq run-bg-color rbg run-bg-x rx run-bg-w rw))
                       (flush-bg))
                     ;; Borders / rules / decorations
                     (when (> rw 0.0)
                       (when-let* ((ol (plist-get style :overline)))
                         (push (format "<line x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" stroke=\"%s\" stroke-width=\"1\"/>"
                                       rx (+ ly 0.5) (+ rx rw) (+ ly 0.5) ol)
                               dec-elems))
                       (when-let* ((ul (plist-get style :underline)))
                         (let ((uy (- (+ ly lh) 0.7)))
                           (if (eq (plist-get style :underline-style) 'wave)
                               (push (format "<path d=\"%s\" fill=\"none\" stroke=\"%s\" stroke-width=\"1\"/>"
                                             (etaf-export--wave-path rx uy rw) ul)
                                     dec-elems)
                             (push (format "<line x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" stroke=\"%s\" stroke-width=\"1\"/>"
                                           rx uy (+ rx rw) uy ul)
                                   dec-elems))))
                       (when-let* ((st (plist-get style :strike)))
                         (let ((sy (+ ly (* lh 0.54))))
                           (push (format "<line x1=\"%.2f\" y1=\"%.2f\" x2=\"%.2f\" y2=\"%.2f\" stroke=\"%s\" stroke-width=\"1\"/>"
                                         rx sy (+ rx rw) sy st)
                                 dec-elems)))
                       (when-let* ((bx (plist-get style :box)))
                         (let ((bw (max 1 (plist-get style :box-width))))
                           (push (format "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" fill=\"none\" stroke=\"%s\" stroke-width=\"%d\"/>"
                                         (+ rx 0.5) (+ ly 0.5) (max 1.0 (- rw 1.0)) (max 1.0 (- lh 1.0)) bx bw)
                                 dec-elems))))
                     ;; Inline (non-stitched) 1-row images, icons & Ebox corner SVGs
                     (when (and (eq kind 'image) (not (plist-get run :stitched)))
                       (let ((disp (plist-get run :display)))
                         (when-let* ((pair (etaf-export--image-bytes disp)))
                           (let* ((ih (plist-get run :h))
                                  (img-ascent (plist-get disp :ascent))
                                  (ascent-ratio (/ base-ascent (max 1.0 base-lh)))
                                  (iy (cond
                                       ((plist-get disp :slice) ly)
                                       ((eq img-ascent 'center)
                                        (+ ly (/ (max 0.0 (- lh ih)) 2.0)))
                                       ((and (numberp img-ascent) (< ih lh))
                                        (max ly
                                             (min (+ ly (- lh ih))
                                                  (- (+ ly (* lh ascent-ratio))
                                                     (* ih (/ (float img-ascent) 100.0))))))
                                       (t ly))))
                             (setq svg-seq (1+ svg-seq))
                             (push (if (eq (car pair) 'svg)
                                       (etaf-export--embed-inline-svg
                                        (cdr pair) rx iy rw ih
                                        (format "p%d_i%d_" page-idx svg-seq)
                                        theme orig-bg
                                        (plist-get style :fg))
                                     (etaf-export--embed-raster (car pair) (cdr pair) rx iy rw ih))
                                   img-elems)))))
                     ;; Visible text runs
                     (when (eq kind 'text)
                       (let ((txt (plist-get run :text)))
                         (when (string-match-p "[^ \t]" txt)
                           (let* ((sc (plist-get style :scale))
                                  (fs (* base-fs sc))
                                  (raise (or (plist-get run :raise) 0.0))
                                  (ascent-ratio (/ base-ascent (max 1.0 base-lh)))
                                  (baseline (- (+ ly (* lh ascent-ratio)) (* raise lh)))
                                  (fam (or (plist-get style :family) font-family))
                                  (fw (if (plist-get style :bold) " font-weight=\"700\"" ""))
                                  (fst (if (plist-get style :italic) " font-style=\"italic\"" "")))
                             (push (format "<text x=\"%.2f\" y=\"%.2f\" fill=\"%s\" font-family=\"%s\" font-size=\"%.2f\"%s%s xml:space=\"preserve\">%s</text>"
                                           rx baseline (plist-get style :fg)
                                           (etaf-export--xml-escape fam) fs fw fst
                                           (etaf-export--xml-escape txt))
                                   txt-elems)))))))
                 (flush-bg))))
    ;; 2. Emit stitched multi-row images intersecting this page.
    ;; Wide diagrams exceeding the canonical text column clamp cleanly to
    ;; [0, content-w] and scale proportionally via `preserveAspectRatio="xMidYMid meet"'
    ;; so one wide diagram never shrinks the entire document's body typography.
    (dolist (img images)
      (let* ((iy (plist-get img :y))
             (ih (plist-get img :h))
             (iy-end (+ iy ih)))
        (when (and (< iy y1) (> iy-end y0))
          (let* ((raw-x (- (plist-get img :x) min-x))
                 (raw-w (plist-get img :w))
                 (rw (min raw-w content-w))
                 (rx (if (> raw-w content-w)
                         0.0
                       (max 0.0 (min raw-x (- content-w rw)))))
                 (ry (- iy y0)))
            (setq svg-seq (1+ svg-seq))
            (push (if (eq (plist-get img :type) 'svg)
                      (etaf-export--embed-inline-svg
                       (plist-get img :bytes) rx ry rw ih
                       (format "p%d_m%d_" page-idx svg-seq)
                       theme orig-bg)
                    (etaf-export--embed-raster (plist-get img :type) (plist-get img :bytes) rx ry rw ih))
                  img-elems)))))
    ;; 3. Optional subtle footer page number on multi-page exports
    (let* ((clip-h (max 1.0 (- y1 y0)))
           (footer-elem
            (when (and page-numbers (> total-pages 1))
              (let ((muted (etaf-ui-color-mix canvas-fg canvas-bg 0.55)))
                (format "<text x=\"%.2f\" y=\"%.2f\" text-anchor=\"middle\" fill=\"%s\" font-family=\"%s\" font-size=\"9\">%d / %d</text>"
                        (/ page-w 2.0) (- page-h 14.0) muted
                        (etaf-export--xml-escape font-family)
                        page-idx total-pages)))))
      (concat
       (format "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"%.2fpt\" height=\"%.2fpt\" viewBox=\"0 0 %.2f %.2f\">\n"
               page-w page-h page-w page-h)
       (format "<defs><clipPath id=\"page_clip_%d\"><rect x=\"-2\" y=\"0\" width=\"%.2f\" height=\"%.2f\"/></clipPath></defs>\n"
               page-idx (+ content-w 4.0) (+ clip-h 2.0))
       (format "<rect x=\"0\" y=\"0\" width=\"%.2f\" height=\"%.2f\" fill=\"%s\"/>\n"
               page-w page-h canvas-bg)
       (format "<g transform=\"translate(%.2f,%.2f) scale(%.6f)\" clip-path=\"url(#page_clip_%d)\">\n"
               offset-x margin-y scale page-idx)
       (mapconcat #'identity (nreverse bg-elems) "\n") "\n"
       (mapconcat #'identity (nreverse img-elems) "\n") "\n"
       (mapconcat #'identity (nreverse dec-elems) "\n") "\n"
       (mapconcat #'identity (nreverse txt-elems) "\n") "\n"
       "</g>\n"
       (if footer-elem (concat footer-elem "\n") "")
       "</svg>\n"))))

(cl-defun etaf-export--render-svg-pages (snapshot &key (page-mode 'a4) (margin nil) (page-numbers t))
  "Render SNAPSHOT into a list of SVG document strings for PAGE-MODE."
  (let* ((layout (etaf-export--paginate snapshot page-mode margin page-numbers))
         (pages (plist-get layout :pages))
         (total (length pages)))
    (list :layout layout
          :svg-pages (mapcar (lambda (pg)
                               (etaf-export--render-page-svg snapshot layout pg total page-numbers))
                             pages))))

(defun etaf-export--compose-preview-svg (page-svg page-w page-h stage-w stage-h stage-bg border-color shadow-color)
  "Compose PAGE-SVG (PAGE-W x PAGE-H pt) into a STAGE-W x STAGE-H px SVG.
The outer SVG declares exact integer pixel dimensions so Emacs's `ebox-image'
renderer receives a 1:1 pixel match without aspect-ratio rejection, showing the
centered paper sheet over STAGE-BG with a subtle drop shadow and 1px border."
  (let* ((sw (max 32 (round stage-w)))
         (sh (max 32 (round stage-h)))
         (pw (max 1.0 (float page-w)))
         (ph (max 1.0 (float page-h)))
         (pad-x (min 14.0 (* sw 0.04)))
         (pad-y (min 12.0 (* sh 0.04)))
         (avail-w (max 16.0 (- sw (* 2.0 pad-x))))
         (avail-h (max 16.0 (- sh (* 2.0 pad-y))))
         (scale (min (/ avail-w pw) (/ avail-h ph)))
         (sheet-w (* pw scale))
         (sheet-h (* ph scale))
         (sx (/ (- sw sheet-w) 2.0))
         (sy (/ (- sh sheet-h) 2.0))
         (inner (or (cdr (etaf-export--split-svg-root page-svg)) "")))
    (concat
     (format "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n"
             sw sh sw sh)
     (format "<rect x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"%s\"/>\n"
             sw sh (etaf-export--xml-escape (or stage-bg "#e5e7eb")))
     (format "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" rx=\"2\" fill=\"%s\" fill-opacity=\"0.22\"/>\n"
             (+ sx 2.0) (+ sy 3.0) sheet-w sheet-h
             (etaf-export--xml-escape (or shadow-color "#000000")))
     (format "<svg x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" viewBox=\"0 0 %.2f %.2f\" preserveAspectRatio=\"xMidYMid meet\" overflow=\"hidden\">\n%s\n</svg>\n"
             sx sy sheet-w sheet-h pw ph inner)
     (format "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" fill=\"none\" stroke=\"%s\" stroke-width=\"1\"/>\n"
             (+ sx 0.5) (+ sy 0.5) (max 1.0 (- sheet-w 1.0)) (max 1.0 (- sheet-h 1.0))
             (etaf-export--xml-escape (or border-color "#cbd5e1")))
     "</svg>\n")))

(defun etaf-export--preview-svg-descriptor (page-svg page-w page-h stage-w stage-h stage-bg border-color shadow-color)
  "Return an in-memory Emacs SVG image descriptor for previewing PAGE-SVG."
  (let ((svg (etaf-export--compose-preview-svg
              page-svg page-w page-h stage-w stage-h
              stage-bg border-color shadow-color)))
    (list 'image
          :type 'svg
          :data (encode-coding-string svg 'utf-8-unix)
          :scale 1)))

(provide 'etaf-export-svg)
;;; etaf-export-svg.el ends here
