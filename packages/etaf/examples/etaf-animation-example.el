;;; etaf-animation-example.el --- Full-buffer animation theatre -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A full-buffer theatre for the shared animation clock: twenty panels cover
;; frame sequences (typewriter, spinners, heartbeat, matrix, morse lamp),
;; precomputed frame fields (snow, firework), transitions with retargeted loops
;; (color pulse, bouncing ball, DVD logo, bobbing letters, pendulum, fish,
;; the moving rail), paint-heavy fields (gradient wave, plasma, heat) and text
;; updates (spectrum, shimmer, loading, neon flicker, rainbow).
;;
;; The control bar pauses the clock, changes its speed and frame rate live; the
;; edit pad is a native editable Host, so typing, selection, undo and input
;; methods keep working while every animation runs.  Animations never touch
;; keys, focus, point or other buffers; `etaf-animation-enabled' is the global
;; off switch.  The gallery reflows from four columns to one and controls
;; wrap as the window narrows.  Content scrolls vertically; the minimum usable
;; viewport is 28 columns by 12 lines, with clipping below that size.
;; The example configures a one-pixel right fringe in its displaying windows
;; so Emacs does not reserve a whole text column for a truncation marker.
;;
;; Function: etaf-animation-example-view ()
;; Return the theatre View for mounting with `etaf-mount'.  One theatre at a
;; time owns the controls; unmount restores the previous global clock settings.
;; Function: etaf-animation-example-open ()
;; Mount the theatre, return its buffer, and display it when called interactively.

;;; Code:

(require 'cl-lib)
(require 'etaf)

(defconst etaf-animation-example-buffer-name "*ETAF Animation Example*"
  "Buffer opened by `etaf-animation-example-open'.")

(defconst etaf-animation-example-tau 6.283185307179586
  "One full turn in radians.")

(defconst etaf-animation-example-typewriter-text
  "时间交给时钟，状态留给自己。"
  "Sentence typed by the typewriter panel.")

(defconst etaf-animation-example-rainbow-text
  "ETAF ANIMATION"
  "Letters whose colors scroll in the rainbow panel.")

(defconst etaf-animation-example-blocks
  " ▁▂▃▄▅▆▇█"
  "Block glyphs from empty to full used by the spectrum.")

(defconst etaf-animation-example-matrix-glyphs
  "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃ0123456789ABCDEF"
  "Alphabet mixed by the matrix columns.")

(defconst etaf-animation-example-morse-code
  "···---···"
  "SOS in Morse code; dots are one unit, dashes three.")

(defvar etaf-animation-example-mode (etaf-ref 'dark)
  "Current theatre Theme mode, `dark' or `light'.")

(defvar etaf-animation-example-wave-colors
  '("#22D3EE" "#818CF8" "#F472B6" "#FBBF24")
  "Gradient stops cycled by the wave strip.")

(defvar etaf-animation-example-plasma-colors
  '("#03121C" "#0E4F63" "#2AB7A9" "#F5E663")
  "Gradient stops cycled by the plasma field.")

(defvar etaf-animation-example-heat-colors
  '("#101521" "#7F1D1D" "#F97316" "#FDE047")
  "Gradient stops cycled by the heat field.")

(defvar etaf-animation-example-rainbow-colors
  '("#FF5D8F" "#F5E663" "#5EEAD4" "#8BD5FF")
  "Gradient stops cycled by the rainbow letters.")

(defvar etaf-animation-example-palette
  '(:bg ("#F6F7F9" . "#0E1013")
    :bar ("#FFFFFF" . "#10151C")
    :panel ("#FFFFFF" . "#151A22")
    :pad ("#F1F3F6" . "#12161D")
    :line ("#D5DBE3" . "#2A3340")
    :ink ("#1F2933" . "#E8EDF5")
    :dim ("#7A8694" . "#6C7A8D")
    :accent ("#2563EB" . "#8BD5FF")
    :track ("#E3E7EC" . "#232B36")
    :pad-ink ("#8F5D00" . "#F5E663")
    :ctl ("#E9EDF1" . "#1B2430")
    :ctl-ink ("#4A5560" . "#9AA7B8")
    :ctl-active ("#CFE2FF" . "#2B4A63")
    :ctl-active-ink ("#1D4ED8" . "#8BD5FF"))
  "Light and dark colors of the theatre.")

(defconst etaf-animation-example-wave-width 22
  "Cells in the wave strip.")

(defconst etaf-animation-example-plasma-columns 12
  "Columns in the plasma field.")

(defconst etaf-animation-example-plasma-rows 4
  "Rows in the plasma field.")

(defconst etaf-animation-example-heat-columns 16
  "Columns in the heat field.")

(defconst etaf-animation-example-heat-rows 4
  "Rows in the heat field.")

(defconst etaf-animation-example-snow-columns 22
  "Columns in the snow field.")

(defconst etaf-animation-example-snow-rows 5
  "Rows in the snow field.")

;;;; Looping and value helpers

(defun etaf-animation-example--flip (target low high)
  "Retarget TARGET between LOW and HIGH, opposite the value it holds."
  (setf (etaf-value target)
        (if (equal (etaf-value target) high) low high)))

(defun etaf-animation-example--advance (target)
  "Retarget TARGET one step past the value it holds, looping a ramp."
  (setf (etaf-value target) (+ (etaf-value target) 1.0)))

(defun etaf-animation-example--step-color (from to value steps)
  "Return the color at VALUE (0 to 1) between FROM and TO, quantized to STEPS."
  (etaf-animation-interpolate
   from to
   (/ (round (* steps value)) (float steps))))

(defun etaf-animation-example--interpolate-stops (stops position steps)
  "Return the color at POSITION through STOPS, quantized to STEPS each."
  (let* ((position (mod position (float (length stops))))
         (left (floor position))
         (fraction (/ (round (* steps (- position left))) (float steps))))
    (etaf-animation-interpolate
     (nth left stops)
     (nth (mod (1+ left) (length stops)) stops)
     fraction)))

(defun etaf-animation-example--wave-color (phase index)
  "Return the color of wave cell INDEX for PHASE."
  (etaf-animation-example--interpolate-stops
   etaf-animation-example-wave-colors
   (* (length etaf-animation-example-wave-colors)
      (mod (+ phase (/ (float index) etaf-animation-example-wave-width)) 1.0))
   8))

(defun etaf-animation-example--plasma-color (phase row column)
  "Return the plasma color for ROW and COLUMN at PHASE."
  (let* ((value (+ (sin (+ (* 1.15 row) (* 0.65 column) phase))
                   (* 0.6 (sin (- (* 0.8 column) (* 0.45 phase))))
                   1.6)))
    (etaf-animation-example--interpolate-stops
     etaf-animation-example-plasma-colors (min 3.999 (* value 1.25)) 5)))

(defun etaf-animation-example--heat-color (phase row column)
  "Return the heat color for ROW and COLUMN at PHASE."
  (let* ((cx (+ 7.5 (* 5.5 (cos (* etaf-animation-example-tau phase)))))
         (cy (+ 2.0 (* 1.5 (sin (* etaf-animation-example-tau phase)))))
         (distance (sqrt (+ (expt (- column cx) 2.0) (expt (- row cy) 2.0))))
         (value (max 0.0 (- 1.0 (/ distance 9.0)))))
    (etaf-animation-example--interpolate-stops
     etaf-animation-example-heat-colors (* value 4.0) 6)))

(defun etaf-animation-example--rainbow-color (phase index)
  "Return the rainbow color of letter INDEX at PHASE."
  (etaf-animation-example--interpolate-stops
   etaf-animation-example-rainbow-colors
   (* (length etaf-animation-example-rainbow-colors)
      (mod (+ phase (/ index 16.0)) 1.0))
   6))

(defun etaf-animation-example--spectrum (phase width)
  "Return a WIDTH glyph spectrum line for PHASE."
  (let* ((glyphs etaf-animation-example-blocks)
         (top (1- (length glyphs))))
    (apply #'string
           (cl-loop for index below width
                    collect (let* ((wave (+ (sin (+ (* index 0.55) (* phase 6.0)))
                                           (* 0.5 (sin (+ (* index 1.31)
                                                          (* phase 9.7))))))
                                   (level (round (* 0.5 (1+ wave) top))))
                              (aref glyphs (max 0 (min top level))))))))

(defun etaf-animation-example--rotations (text)
  "Return every one-character rotation of TEXT."
  (cl-loop for offset below (length text)
           collect (concat (substring text offset) (substring text 0 offset))))

(defun etaf-animation-example--matrix-frames (seed length)
  "Return rotation frames of a LENGTH-line glyph column for SEED."
  (let* ((alphabet etaf-animation-example-matrix-glyphs)
         (size (length alphabet))
         (glyphs (cl-loop for step below length
                          collect (aref alphabet (mod (* (+ seed 3) (+ step 5) 17)
                                                      size)))))
    (cl-loop for offset below (length glyphs)
             collect (mapconcat #'string
                                (append (cl-subseq glyphs offset)
                                        (cl-subseq glyphs 0 offset))
                                "\n"))))

(defun etaf-animation-example--snow-frames ()
  "Return falling-snow frames."
  (let* ((rows etaf-animation-example-snow-rows)
         (columns etaf-animation-example-snow-columns)
         (flakes (cl-loop for seed from 1 to 24
                          collect (cons (mod (* seed 7) columns)
                                        (1+ (mod seed 3))))))
    (cl-loop for frame below 12
             collect
             (let ((grid (make-vector rows nil)))
               (dotimes (row rows)
                 (aset grid row (make-string columns ?\s)))
               (dolist (flake flakes)
                 (let* ((column (car flake))
                        (row (mod (+ (* frame (cdr flake)) (* 3 column)) rows))
                        (line (aref grid row)))
                   (aset line column ?*)))
               (mapconcat #'identity (append grid nil) "\n")))))

(defun etaf-animation-example--firework-frames ()
  "Return expanding firework frames ending in a blank pause."
  (let* ((rows 5) (columns 15) (center-y 2) (center-x 7)
         (blank (mapconcat #'identity
                           (cl-loop repeat rows
                                    collect (make-string columns ?\s))
                           "\n"))
         (bursts (cl-loop for radius from 0 to 5
                          collect
                          (let ((grid (make-vector rows nil)))
                            (dotimes (row rows)
                              (aset grid row (make-string columns ?\s)))
                            (dotimes (row rows)
                              (dotimes (column columns)
                                (when (= (+ (abs (- row center-y))
                                            (abs (- column center-x)))
                                         radius)
                                  (aset (aref grid row) column ?*))))
                            (mapconcat #'identity (append grid nil) "\n")))))
    (append bursts (list blank))))

(defun etaf-animation-example--morse-frames ()
  "Return lamp frames blinking `etaf-animation-example-morse-code'."
  (let (frames)
    (cl-loop for char across etaf-animation-example-morse-code
             for index from 1
             do (dotimes (_ (if (eq char ?-) 3 1))
                  (push "●" frames))
             do (dotimes (_ (if (zerop (mod index 3)) 3 1))
                  (push " " frames)))
    (nreverse frames)))

(defconst etaf-animation-example-neon-colors
  '("#FF5D8F" "#8BD5FF" "#F5E663" "#5EEAD4" "#FF5D8F" "#394150" "#394150")
  "Flicker frames of the neon sign.")

(defun etaf-animation-example--rail (phase total width)
  "Return (LEFT LIT RIGHT) rail pieces for PHASE across TOTAL cells."
  (let* ((span (max 1 (- total width)))
         (start (min span (floor (* (mod phase 1.0) span)))))
    (list (make-string start ?─)
          (make-string width ?━)
          (make-string (- span start) ?─))))

(defun etaf-animation-example--shimmer (phase width)
  "Return a shimmering WIDTH bar for PHASE."
  (let* ((position (floor (* (mod phase 1.0) (1- width))))
         (head (min 4 (- width position))))
    (concat (make-string position ?░)
            (make-string head ?▓)
            (make-string (- width position head) ?░))))

(defun etaf-animation-example--bob (phase index)
  "Return a 0 to 3 line offset bob for letter INDEX at PHASE."
  (round (* 1.5 (+ 1.0 (sin (+ (* index 0.9) (* phase 2.0)))))))

(defun etaf-animation-example--swing (phase amplitude center)
  "Return the horizontal position of a pendulum at PHASE."
  (+ center (* amplitude (sin (* etaf-animation-example-tau phase)))))

;;;; Card frame

(etaf-define-component etaf-animation-example-card (&key title kind hint on-press)
  "Frame one panel with TITLE, its animation KIND and a HINT."
  :view
  (flex :class "card" :flex-direction 'column :justify-content 'center
        :role (and on-press 'button) :tab-index (and on-press 0)
        :on-press on-press
    (flex :class "card-head" :height '(lh 1) :gap '((lh 0) (ch 1))
      (text :class "card-title" (expr title))
      (text :class "card-kind" (expr (format "%s · %s" kind hint))))
    (slot))
  :styles
  (("&" :width stretch :height stretch :min-width (px 0)
    :padding-left (ch 1) :padding-right (px 0)
    :overflow hidden
    :bgcolor (etaf-theme-token :panel)
    :border-style solid :border-width (px 1)
    :border-color (etaf-theme-token :line))
   (".card-head" :margin-bottom (lh 0))
   (".card-title" :color (etaf-theme-token :ink) :font-weight bold)
   (".card-kind" :color (etaf-theme-token :dim) :font-size 0.85)))

;;;; Typewriter

(etaf-define-component etaf-animation-example-typewriter-card ()
  "Type one sentence with a blinking cursor."
  :bindings ((frame (etaf-animation-frames
                     (append (number-sequence 0 (length etaf-animation-example-typewriter-text))
                             (make-list 14 (length etaf-animation-example-typewriter-text)))
                     :interval 0.09 :name 'typewriter))
             (cursor (etaf-animation-frames '("▌" " ") :interval 0.45
                                            :name 'cursor)))
  :view
  (etaf-animation-example-card :title "TYPEWRITER" :kind "frames" :hint "text reveal"
    (box :class "typing" :height '(lh 2)
      (text :class "typed"
            (expr (substring etaf-animation-example-typewriter-text
                             0 (min (length etaf-animation-example-typewriter-text)
                                    (etaf-value frame)))))
      (text :class "cursor" (expr (etaf-value cursor)))))
  :styles
  ((".typing" :color "#9FE8A0")
   (".typed" :font-weight bold)
   (".cursor" :color "#9FE8A0")))

;;;; Spinner shelf

(etaf-define-component etaf-animation-example-spinners-card ()
  "Run six frame sequences with different intervals side by side."
  :bindings ((braille (etaf-animation-frames
                       '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
                       :interval 0.07 :name 'spinner-braille))
             (moon (etaf-animation-frames '("◐" "◓" "◑" "◒")
                                          :interval 0.2 :name 'spinner-moon))
             (line (etaf-animation-frames '("|" "/" "-" "\\")
                                          :interval 0.12 :name 'spinner-line))
             (triangle (etaf-animation-frames '("◢" "◣" "◤" "◥")
                                              :interval 0.15 :name 'spinner-triangle))
             (dot (etaf-animation-frames '("•" "◦")
                                         :interval 0.3 :name 'spinner-dot))
             (meter (etaf-animation-frames
                     '("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█" "▇" "▆" "▅" "▄" "▃" "▂")
                     :interval 0.09 :name 'spinner-meter)))
  :view
  (etaf-animation-example-card :title "SPINNERS" :kind "frames" :hint "six intervals"
    (flex :class "shelf" :height '(lh 2)
      (text :class "s1" (expr (etaf-value braille)))
      (text :class "s2" (expr (etaf-value moon)))
      (text :class "s3" (expr (etaf-value line)))
      (text :class "s4" (expr (etaf-value triangle)))
      (text :class "s5" (expr (etaf-value dot)))
      (text :class "s6" (expr (etaf-value meter)))))
  :styles
  ((".shelf" :gap ((lh 0) (ch 2)))
   (".s1" :color "#8BD5FF") (".s2" :color "#B197FC")
   (".s3" :color "#9FE8A0") (".s4" :color "#FFD166")
   (".s5" :color "#FF8FA3") (".s6" :color "#5EEAD4")))

;;;; Heartbeat trace

(etaf-define-component etaf-animation-example-ecg-card ()
  "Slide a heartbeat waveform one glyph at a time."
  :bindings ((trace (etaf-animation-frames
                     (etaf-animation-example--rotations
                      "▁▁▁▁▂▅▇▅▂▁▁▁▁▁▁▃▆▄▂▁▁")
                     :interval 0.07 :name 'ecg)))
  :view
  (etaf-animation-example-card :title "HEARTBEAT" :kind "frames" :hint "sliding waveform"
    (box :class "ecg" :height '(lh 2)
      (text (expr (etaf-value trace)))))
  :styles
  ((".ecg" :color "#FF6B6B" :font-weight bold)))

;;;; Matrix rain

(etaf-define-component etaf-animation-example-rain-card ()
  "Fall six glyph columns with staggered frame sequences."
  :bindings ((column-0 (etaf-animation-frames (etaf-animation-example--matrix-frames 1 5) :interval 0.12 :name 'rain-0))
             (column-1 (etaf-animation-frames (etaf-animation-example--matrix-frames 2 5) :interval 0.19 :name 'rain-1))
             (column-2 (etaf-animation-frames (etaf-animation-example--matrix-frames 3 5) :interval 0.15 :name 'rain-2))
             (column-3 (etaf-animation-frames (etaf-animation-example--matrix-frames 4 5) :interval 0.24 :name 'rain-3))
             (column-4 (etaf-animation-frames (etaf-animation-example--matrix-frames 5 5) :interval 0.13 :name 'rain-4))
             (column-5 (etaf-animation-frames (etaf-animation-example--matrix-frames 6 5) :interval 0.21 :name 'rain-5)))
  :view
  (etaf-animation-example-card :title "MATRIX" :kind "frames" :hint "staggered columns"
    (flex :class "rain" :height '(lh 5)
      (text (expr (etaf-value column-0)))
      (text (expr (etaf-value column-1)))
      (text (expr (etaf-value column-2)))
      (text (expr (etaf-value column-3)))
      (text (expr (etaf-value column-4)))
      (text (expr (etaf-value column-5)))))
  :styles
  ((".rain" :gap ((lh 0) (ch 1)) :color "#2AF598")))

;;;; Morse lamp

(etaf-define-component etaf-animation-example-morse-card ()
  "Blink SOS on a lamp one Morse unit at a time."
  :bindings ((lamp (etaf-animation-frames (etaf-animation-example--morse-frames)
                                          :interval 0.13 :name 'morse)))
  :view
  (etaf-animation-example-card :title "MORSE" :kind "frames" :hint "SOS lamp"
    (flex :class "morse" :height '(lh 2)
      (text :class "lamp" (expr (etaf-value lamp)))
      (text :class "morse-code" " ···---···")))
  :styles
  ((".morse" :justify-content flex-start :gap ((lh 0) (ch 2)))
   (".lamp" :color "#FFD166" :font-weight bold :font-size 1.15)
   (".morse-code" :color (etaf-theme-token :dim))))

;;;; Snow field

(etaf-define-component etaf-animation-example-snow-card ()
  "Fall a field of flakes at three different speeds."
  :bindings ((snow (etaf-animation-frames (etaf-animation-example--snow-frames)
                                          :interval 0.24 :name 'snow)))
  :view
  (etaf-animation-example-card :title "SNOW" :kind "frames" :hint "frame field"
    (text :class "snow" (expr (etaf-value snow))))
  :styles
  ((".snow" :color "#BFD8FF")))

;;;; Firework

(etaf-define-component etaf-animation-example-firework-card ()
  "Expand a ring of sparks and pause before the next burst."
  :bindings ((burst (etaf-animation-frames (etaf-animation-example--firework-frames)
                                           :interval 0.18 :name 'firework)))
  :view
  (etaf-animation-example-card :title "FIREWORK" :kind "frames" :hint "precomputed burst"
    (text :class "firework" (expr (etaf-value burst))))
  :styles
  ((".firework" :color "#FBBF24")))

;;;; Spectrum

(etaf-define-component etaf-animation-example-spectrum-card ()
  "Draw a moving spectrum with block glyphs in one text node."
  :bindings ((phase (etaf-ref 0.0))
             (tick (etaf-transition
                    phase :duration 2.6 :easing 'linear :name 'spectrum
                    :on-complete (lambda ()
                                   (etaf-animation-example--advance phase)))))
  :setup (setf (etaf-value phase) 1.0)
  :view
  (etaf-animation-example-card :title "SPECTRUM" :kind "text" :hint "one changed line"
    (box :class "spectrum" :height '(lh 2)
      (text (expr (etaf-animation-example--spectrum (etaf-value tick) 24)))))
  :styles
  ((".spectrum" :color "#5EEAD4" :font-weight bold)))

;;;; Loading loop

(etaf-define-component etaf-animation-example-loading-card ()
  "Fill a bar to 100 percent, reset and fill again."
  :bindings ((phase (etaf-ref 0.0))
             (tick (etaf-transition
                    phase :duration 1.6 :easing 'linear :name 'loading
                    :on-complete (lambda ()
                                   (etaf-animation-example--advance phase)))))
  :setup (setf (etaf-value phase) 1.0)
  :view
  (etaf-animation-example-card :title "LOADING" :kind "layout" :hint "fill and reset"
    (column :class "loading" :height '(lh 2)
      (box :class "track" :width '(ch 20) :height '(lh 1) :bgcolor (etaf-theme-token :track)
           (box :width (list 'ch (* 20 (mod (etaf-value tick) 1.0)))
                :height '(lh 1) :bgcolor "#5EEAD4"))
      (text :class "loading-note"
            (expr (format "%3d%%" (round (* 100 (mod (etaf-value tick) 1.0))))))))
  :styles
  ((".loading-note" :color (etaf-theme-token :dim) :font-size 0.85)))

;;;; Neon flicker

(etaf-define-component etaf-animation-example-neon-card ()
  "Flicker a neon sign through a short color sequence."
  :bindings ((flicker (etaf-animation-frames etaf-animation-example-neon-colors
                                             :interval 0.09 :name 'neon)))
  :view
  (etaf-animation-example-card :title "NEON" :kind "frames" :hint "color flicker"
    (box :class "neon" :height '(lh 2)
      (text :color (etaf-value flicker) "◉ OPEN")))
  :styles
  ((".neon" :font-weight bold :font-size 1.15)))

;;;; Bouncing ball

(etaf-define-component etaf-animation-example-bounce-card ()
  "Bounce a ball between the floor and the ceiling."
  :bindings ((height (etaf-ref 0.0))
             (lift (etaf-transition
                    height :duration 0.5 :easing 'ease-in-out :name 'bounce
                    :on-complete (lambda ()
                                   (etaf-animation-example--flip height 0.0 3.0)))))
  :setup (setf (etaf-value height) 3.0)
  :view
  (etaf-animation-example-card :title "GRAVITY" :kind "transition" :hint "layout + retarget"
    (box :class "stage" :height '(lh 4) :position 'relative
      (box :class "floor" :position 'absolute :left '(ch 0) :top '(lh 3)
           :width 'stretch (text "⠐⠒⠒⠒⠒⠒⠒⠒⠒⠒⠒⠒⠒⠒⠒⠒⠂"))
      (box :class "ball" :position 'absolute :left '(ch 10)
           :top (list 'lh (- 3.0 (etaf-value lift)))
           (text "●"))))
  :styles
  ((".stage" :color "#57C7FF" :text-align center)
   (".floor" :color "#56637A")
   (".ball" :color "#FFD166" :font-weight bold)))

;;;; DVD logo

(etaf-define-component etaf-animation-example-dvd-card ()
  "Drift a logo across the stage and bounce it off the edges."
  :bindings ((x (etaf-ref 0.0))
             (xv (etaf-transition
                  x :duration 1.7 :easing 'linear :name 'dvd-x
                  :on-complete (lambda ()
                                 (etaf-animation-example--flip x 0.0 14.0))))
             (y (etaf-ref 0.0))
             (yv (etaf-transition
                  y :duration 1.1 :easing 'linear :name 'dvd-y
                  :on-complete (lambda ()
                                 (etaf-animation-example--flip y 0.0 2.0))))
             (tint (etaf-ref 0.0))
             (color (etaf-transition
                     tint :duration 0.9 :easing 'ease-in-out :name 'dvd-color
                     :on-complete (lambda ()
                                    (etaf-animation-example--flip tint 0.0 1.0)))))
  :setup (setf (etaf-value x) 14.0
               (etaf-value y) 2.0
               (etaf-value tint) 1.0)
  :view
  (etaf-animation-example-card :title "DVD LOGO" :kind "transition" :hint "two axes + paint"
    (box :class "dvd-stage" :height '(lh 3) :position 'relative :overflow 'hidden
      (box :class "dvd" :position 'absolute
           :left (list 'ch (etaf-value xv))
           :top (list 'lh (etaf-value yv))
           (text :color (etaf-animation-example--step-color
                         "#8BD5FF" "#FF8FA3" (etaf-value color) 12)
                 "DVD"))))
  :styles
  ((".dvd" :font-weight bold)))

;;;; Bobbing letters

(etaf-define-component etaf-animation-example-letters-card ()
  "Bob four letters with staggered phase offsets from one ramp."
  :bindings ((phase (etaf-ref 0.0))
             (tick (etaf-transition
                    phase :duration 2.0 :easing 'linear :name 'letters
                    :on-complete (lambda ()
                                   (etaf-animation-example--advance phase)))))
  :setup (setf (etaf-value phase) 1.0)
  :view
  (etaf-animation-example-card :title "LETTERS" :kind "transition" :hint "staggered layout"
    (flex :class "letters" :height '(lh 3) :position 'relative
      (box :for (index (number-sequence 0 3)) :key index
           :position 'absolute
           :left (list 'ch (* 3 index))
           :top (list 'lh (- 2 (etaf-animation-example--bob (etaf-value tick) index)))
           (text (expr (char-to-string (aref "ETAF" index)))))))
  :styles
  ((".letters" :justify-content center :gap ((lh 0) (ch 0)))
   (".letters text" :color "#5EEAD4" :font-weight bold :font-size 1.08)))

;;;; Pendulum

(etaf-define-component etaf-animation-example-pendulum-card ()
  "Swing a weight from a pivot on a sine path."
  :bindings ((phase (etaf-ref 0.0))
             (tick (etaf-transition
                    phase :duration 2.2 :easing 'linear :name 'pendulum
                    :on-complete (lambda ()
                                   (etaf-animation-example--advance phase)))))
  :setup (setf (etaf-value phase) 1.0)
  :view
  (etaf-animation-example-card :title "PENDULUM" :kind "transition" :hint "sine layout"
    (box :class "pendulum" :height '(lh 3) :position 'relative
      (box :position 'absolute :left '(ch 11) :top '(lh 0)
           (text :class "pivot" "┳"))
      (box :position 'absolute :left '(ch 11) :top '(lh 1)
           (text :class "rod" "│"))
      (box :position 'absolute
           :left (list 'ch (+ 9 (round (etaf-animation-example--swing
                                       (etaf-value tick) 8 2))))
           :top (list 'lh 2)
           (text :class "weight" "●"))))
  :styles
  ((".pivot" :color "#6C7A8D")
   (".rod" :color "#39465A")
   (".weight" :color "#FF8FA3" :font-weight bold)))

;;;; Fish tank

(etaf-define-component etaf-animation-example-fish-card ()
  "Swim a fish back and forth with a bobbing depth."
  :bindings ((x (etaf-ref 0.0))
             (xv (etaf-transition
                  x :duration 2.6 :easing 'linear :name 'fish-x
                  :on-complete (lambda ()
                                 (etaf-animation-example--flip x 0.0 16.0))))
             (y (etaf-ref 0.0))
             (yv (etaf-transition
                  y :duration 0.9 :easing 'ease-in-out :name 'fish-y
                  :on-complete (lambda ()
                                 (etaf-animation-example--flip y 0.0 2.0)))))
  :setup (setf (etaf-value x) 16.0
               (etaf-value y) 2.0)
  :view
  (etaf-animation-example-card :title "FISH" :kind "transition" :hint "two-axis drift"
    (box :class "tank" :height '(lh 3) :position 'relative
      (box :position 'absolute
           :left (list 'ch (etaf-value xv))
           :top (list 'lh (etaf-value yv))
           (text :class "fish" "><>°"))))
  :styles
  ((".tank" :text-align left)
   (".fish" :color "#8BD5FF" :font-weight bold)))

;;;; Color pulse

(etaf-define-component etaf-animation-example-pulse-card ()
  "Breathe a row of hearts between two colors."
  :bindings ((level (etaf-ref 0.0))
             (glow (etaf-transition
                    level :duration 0.8 :easing 'ease-in-out :name 'pulse
                    :on-complete (lambda ()
                                   (etaf-animation-example--flip level 0.0 1.0)))))
  :setup (setf (etaf-value level) 1.0)
  :view
  (etaf-animation-example-card :title "PULSE" :kind "transition" :hint "paint + retarget"
    (box :class "pulse" :height '(lh 2)
      (text :class "hearts"
            :color (etaf-animation-example--step-color
                    "#394150" "#FF5D8F" (etaf-value glow) 16)
            "♥ ♥ ♥ ♥ ♥ ♥"))))

;;;; Gradient wave

(etaf-define-component etaf-animation-example-wave-card ()
  "Scroll a four-color gradient across a strip of cells."
  :bindings ((phase (etaf-ref 0.0))
             (tick (etaf-transition
                    phase :duration 2.4 :easing 'linear :name 'wave
                    :on-complete (lambda ()
                                   (etaf-animation-example--advance phase)))))
  :setup (setf (etaf-value phase) 1.0)
  :view
  (etaf-animation-example-card :title "WAVE" :kind "paint" :hint "22 cells, one value"
    (column :class "wave-wrap" :height '(lh 3)
      (flex :class "wave" :height '(lh 1)
            (box :for (index (number-sequence 0 (1- etaf-animation-example-wave-width)))
                 :key index :width '(ch 1) :height '(lh 1)
                 :background-color (etaf-animation-example--wave-color
                                    (etaf-value tick) index)))
      (text :class "wave-note" (expr (format "phase %.2f"
                                             (mod (etaf-value tick) 1.0))))))
  :styles
  ((".wave" :gap ((lh 0) (ch 0)))
   (".wave-note" :color (etaf-theme-token :dim) :font-size 0.85)))

;;;; Plasma field

(etaf-define-component etaf-animation-example-plasma-card ()
  "Drift a two-sine color field over a grid of cells."
  :bindings ((phase (etaf-animation-frames
                     (cl-loop for step below 24 collect (* step 0.28))
                     :interval 0.16 :name 'plasma)))
  :view
  (etaf-animation-example-card :title "PLASMA" :kind "paint" :hint "2D color field"
    (column :class "plasma" :height '(lh 5)
      (flex :class "plasma-row" :for (row (number-sequence 0 (1- etaf-animation-example-plasma-rows)))
            :key row :height '(lh 1)
        (box :for (column (number-sequence 0 (1- etaf-animation-example-plasma-columns)))
             :key column :width '(ch 1) :height '(lh 1)
             :background-color (etaf-animation-example--plasma-color
                                (etaf-value phase) row column)))))
  :styles
  ((".plasma-row" :gap ((lh 0) (ch 0)))))

;;;; Heat field

(etaf-define-component etaf-animation-example-heat-card ()
  "Move a heat source in a circle over a cooling grid."
  :bindings ((phase (etaf-animation-frames
                     (cl-loop for step below 20 collect (* step 0.05))
                     :interval 0.18 :name 'heat)))
  :view
  (etaf-animation-example-card :title "HEAT" :kind "paint" :hint "moving hot spot"
    (column :class "heat" :height '(lh 5)
      (flex :class "heat-row" :for (row (number-sequence 0 (1- etaf-animation-example-heat-rows)))
            :key row :height '(lh 1)
        (box :for (column (number-sequence 0 (1- etaf-animation-example-heat-columns)))
             :key column :width '(ch 1) :height '(lh 1)
             :background-color (etaf-animation-example--heat-color
                                (etaf-value phase) row column)))))
  :styles
  ((".heat-row" :gap ((lh 0) (ch 0)))))

;;;; Rainbow letters

(etaf-define-component etaf-animation-example-rainbow-card ()
  "Scroll a rainbow through the letters of one word."
  :bindings ((phase (etaf-ref 0.0))
             (tick (etaf-transition
                    phase :duration 3.0 :easing 'linear :name 'rainbow
                    :on-complete (lambda ()
                                   (etaf-animation-example--advance phase)))))
  :setup (setf (etaf-value phase) 1.0)
  :view
  (etaf-animation-example-card :title "RAINBOW" :kind "paint" :hint "per-letter color"
    (flex :class "rainbow" :height '(lh 2)
      (text :for (index (number-sequence 0 (1- (length etaf-animation-example-rainbow-text))))
            :key index
            :color (etaf-animation-example--rainbow-color (etaf-value tick) index)
            (expr (char-to-string (aref etaf-animation-example-rainbow-text index))))))
  :styles
  ((".rainbow" :justify-content flex-start :gap ((lh 0) (ch 0)))
   (".rainbow text" :font-weight bold :font-size 1.08)))

;;;; Native editing pad

(defvar etaf-animation-example-session (etaf-ref nil)
  "Active native input session of the editing pad, or nil.")

(defvar etaf-animation-example-draft (etaf-ref "在这里输入，动画继续跑…")
  "Text of the editing pad, including the empty draft.")

(defun etaf-animation-example--edit ()
  "Start native editing of the pad text."
  ;; A stored session whose Runtime is gone or that already ended must not
  ;; block a new one: reopening the theatre reuses this state.
  (let ((runtime (or (etaf-current-runtime)
                     (etaf-runtime-for-buffer (current-buffer))))
        (stored (etaf-value etaf-animation-example-session)))
    (when (and stored
               (not (eq stored (etaf-input-active-p runtime))))
      (setf (etaf-value etaf-animation-example-session) nil)))
  (unless (etaf-value etaf-animation-example-session)
    (setf (etaf-value etaf-animation-example-session)
          (etaf-input-begin
           (or (etaf-current-runtime)
               (etaf-runtime-for-buffer (current-buffer)))
           'notepad
           :on-change (lambda (text)
                        (setf (etaf-value etaf-animation-example-draft) text))
           :keymap (let ((map (make-sparse-keymap)))
                     (define-key map (kbd "C-c C-c")
                                 #'etaf-animation-example--finish-edit)
                     (define-key map (kbd "ESC")
                                 #'etaf-animation-example--finish-edit)
                     (define-key map (kbd "TAB")
                                 #'etaf-animation-example--finish-edit)
                     map)
           :on-leave #'etaf-animation-example--finish-edit)))
  nil)

(defun etaf-animation-example--finish-edit ()
  "End the pad's native input session when one is active."
  (interactive)
  (when-let* ((session (etaf-value etaf-animation-example-session)))
    (unwind-protect
        (etaf-input-end session)
      (setf (etaf-value etaf-animation-example-session) nil))))

(defun etaf-animation-example--clear-draft ()
  "Clear the pad text; the Edit button can reopen an empty draft."
  (etaf-animation-example--finish-edit)
  (setf (etaf-value etaf-animation-example-draft) ""))

;;;; Control bar

(defvar etaf-animation-example-paused (etaf-ref nil)
  "Whether the theatre asked the shared clock to pause.")

(defvar etaf-animation-example-speed (etaf-ref 1.0)
  "Speed multiplier requested by the theatre.")

(defvar etaf-animation-example-fps (etaf-ref 15)
  "Clock frame rate requested by the theatre.")

(defun etaf-animation-example--set-paused (value)
  "Ask the shared clock to pause when VALUE is non-nil."
  (setf (etaf-value etaf-animation-example-paused) (and value t)))

(defun etaf-animation-example--set-speed (value)
  "Ask the shared clock to run at VALUE times normal speed."
  (setf (etaf-value etaf-animation-example-speed) (float value)))

(defun etaf-animation-example--set-fps (value)
  "Ask the shared clock for VALUE frames per second."
  (setf (etaf-value etaf-animation-example-fps) value))

(etaf-define-component etaf-animation-example-control-button
    (&key label active on-press ref)
  "Render one control LABEL; ACTIVE highlights the current choice."
  :view
  (box :class (if active "ctl is-active" "ctl")
       :ref ref :role 'button :tab-index 0 :on-press on-press
    (text (expr label)))
  :styles
  (("&" :padding-inline (ch 1) :border-style solid :border-width (px 1)
    :border-color (etaf-theme-token :line)
    :bgcolor (etaf-theme-token :ctl) :color (etaf-theme-token :ctl-ink))
   ("&.is-active" :bgcolor (etaf-theme-token :ctl-active)
    :color (etaf-theme-token :ctl-active-ink))))

;;;; Theatre

(etaf-define-component etaf-animation-example-theatre ()
  "Reflow a full-width panel grid and controls with the mounted viewport."
  :bindings ((clock-settings (list etaf-animation-paused etaf-animation-speed
                                  etaf-animation-frame-rate))
             (rail (etaf-ref 0.0))
             (rail-tick (etaf-transition
                         rail :duration 1.8 :easing 'linear :name 'rail
                         :on-complete (lambda ()
                                        (etaf-animation-example--advance rail))))
             (columns (etaf-computed
                       (lambda () (max 1 (min 4 (floor (/ (car (etaf-viewport)) 260.0)))))))
             (rail-width
              (etaf-computed
               (lambda ()
                 ;; Whole cells that fit, never one more: an overflowing row
                 ;; makes Emacs paint its truncation glyph at the right edge.
                 ;; One cell of slack: the row must never exceed the window,
                 ;; or Emacs paints its truncation glyph at the right edge.
                 (max 11 (1- (floor (/ (car (etaf-viewport))
                                       (float (frame-char-width)))))))))
             (theme (etaf-computed
                     (lambda ()
                       (etaf-theme-resolve-palette
                        etaf-animation-example-palette
                        (etaf-value etaf-animation-example-mode))))))
  :setup
  (progn
    (etaf-theme-provide theme)
    (setq etaf-animation-paused nil
          etaf-animation-speed 1.0
          etaf-animation-frame-rate 15)
    (setf (etaf-value etaf-animation-example-paused) nil
          (etaf-value etaf-animation-example-speed) 1.0
          (etaf-value etaf-animation-example-fps) 15)
    (etaf-watch etaf-animation-example-paused
                (lambda (value _old) (setq etaf-animation-paused (and value t))))
    (etaf-watch etaf-animation-example-speed
                (lambda (value _old) (setq etaf-animation-speed (float value))))
    (etaf-watch etaf-animation-example-fps
                (lambda (value _old) (setq etaf-animation-frame-rate value)))
    (setf (etaf-value rail) 1.0)
    ;; Open in editing: the pad is the demo's interactive surface, and a
    ;; session is what routes typed keys there.  TAB or ESC leaves it.
    (etaf-on-mounted
     (lambda ()
       (let ((runtime (etaf-current-runtime)))
         (etaf-focus runtime 'pad)
         (etaf-animation-example--edit)
         (unless (etaf-input-active-p runtime)
           (etaf-focus runtime 'pause-button)))))
    (etaf-on-scope-dispose
     (lambda ()
       (etaf-animation-example--finish-edit)
       (setq etaf-animation-paused (nth 0 clock-settings)
             etaf-animation-speed (nth 1 clock-settings)
             etaf-animation-frame-rate (nth 2 clock-settings)))))
  :view
  ;; The panel area scrolls; the rail, controls, pad and footer stay put.
  (flex :class "theatre" :flex-direction 'column :height 'stretch
    (box :class "rail" :ref 'rail :width 'stretch :height '(lh 1)
         :flex-shrink 0 :overflow 'hidden :wrap-mode 'none
      (text :class "rail-dim"
            (expr (nth 0 (etaf-animation-example--rail
                          (etaf-value rail-tick) (etaf-value rail-width) 10))))
      (text :class "rail-lit"
            (expr (nth 1 (etaf-animation-example--rail
                          (etaf-value rail-tick) (etaf-value rail-width) 10))))
      (text :class "rail-dim"
            (expr (nth 2 (etaf-animation-example--rail
                          (etaf-value rail-tick) (etaf-value rail-width) 10)))))
    (flex :class "controls" :ref 'controls :flex-flow '(row wrap) :flex-shrink 0
          :gap '((lh 0) (ch 1))
      (etaf-animation-example-control-button
       :ref 'pause-button
       :label (if (etaf-value etaf-animation-example-paused) "▶ 继续" "⏸ 暂停")
       :active (etaf-value etaf-animation-example-paused)
       :on-press (lambda ()
                   (etaf-animation-example--set-paused
                    (not (etaf-value etaf-animation-example-paused)))))
      (text :class "controls-gap" " ")
      (etaf-animation-example-control-button
       :ref 'speed-half :label "0.5×" :active (equal (etaf-value etaf-animation-example-speed) 0.5)
       :on-press (lambda () (etaf-animation-example--set-speed 0.5)))
      (etaf-animation-example-control-button
       :ref 'speed-normal :label "1×" :active (equal (etaf-value etaf-animation-example-speed) 1.0)
       :on-press (lambda () (etaf-animation-example--set-speed 1.0)))
      (etaf-animation-example-control-button
       :ref 'speed-double :label "2×" :active (equal (etaf-value etaf-animation-example-speed) 2.0)
       :on-press (lambda () (etaf-animation-example--set-speed 2.0)))
      (text :class "controls-gap" " ")
      (etaf-animation-example-control-button
       :ref 'fps-15 :label "15 fps" :active (equal (etaf-value etaf-animation-example-fps) 15)
       :on-press (lambda () (etaf-animation-example--set-fps 15)))
      (etaf-animation-example-control-button
       :ref 'fps-30 :label "30 fps" :active (equal (etaf-value etaf-animation-example-fps) 30)
       :on-press (lambda () (etaf-animation-example--set-fps 30)))
      (etaf-animation-example-control-button
       :ref 'fps-60 :label "60 fps" :active (equal (etaf-value etaf-animation-example-fps) 60)
       :on-press (lambda () (etaf-animation-example--set-fps 60)))
      (text :class "controls-gap" " ")
      (etaf-animation-example-control-button
       :ref 'theme-toggle
       :label (if (eq (etaf-value etaf-animation-example-mode) 'light)
                  "☾ 暗色" "☀ 亮色")
       :active (eq (etaf-value etaf-animation-example-mode) 'light)
       :on-press (lambda ()
                   (setf (etaf-value etaf-animation-example-mode)
                         (if (eq (etaf-value etaf-animation-example-mode) 'light)
                             'dark 'light))))
      (text :class "controls-state" :if (>= (car (etaf-viewport)) 600)
            (expr (format "   speed %.2g× · clock %s fps · %s"
                          (etaf-value etaf-animation-example-speed)
                          (number-to-string (etaf-value etaf-animation-example-fps))
                          (if (etaf-value etaf-animation-example-paused) "paused" "running")))))
    (grid :class "panels" :ref 'panels :width 'stretch
          :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 6)
          :overflow 'scroll
          :grid-template-columns (make-list (etaf-value columns) '(minmax (px 0) (fr 1)))
          :grid-auto-rows '(minmax (lh 6) (fr 1)) :gap '((lh 1) (ch 1))
      (etaf-animation-example-typewriter-card)
      (etaf-animation-example-spinners-card)
      (etaf-animation-example-ecg-card)
      (etaf-animation-example-rain-card)
      (etaf-animation-example-morse-card)
      (etaf-animation-example-snow-card)
      (etaf-animation-example-firework-card)
      (etaf-animation-example-spectrum-card)
      (etaf-animation-example-loading-card)
      (etaf-animation-example-neon-card)
      (etaf-animation-example-bounce-card)
      (etaf-animation-example-dvd-card)
      (etaf-animation-example-letters-card)
      (etaf-animation-example-pendulum-card)
      (etaf-animation-example-fish-card)
      (etaf-animation-example-pulse-card)
      (etaf-animation-example-wave-card)
      (etaf-animation-example-plasma-card)
      (etaf-animation-example-heat-card)
      (etaf-animation-example-rainbow-card))
    ;; The whole editing area starts a session on press; an empty draft
    ;; paints nothing, so the text node alone is not clickable.
    (flex :class "pad" :ref 'pad :height '(lh 7) :flex-shrink 0 :overflow 'hidden
          :flex-direction 'column :tab-index 0
          :on-press #'etaf-animation-example--edit
          :gap '((lh 0) (px 0))
      (flex :class "pad-head" :flex-flow '(row wrap) :flex-shrink 0 :gap '((lh 0) (ch 1))
        (text :class "pad-title" "EDIT PAD")
        (etaf-animation-example-control-button
         :ref 'edit-button :label "编辑" :active (and (etaf-value etaf-animation-example-session) t)
         :on-press #'etaf-animation-example--edit)
        (etaf-animation-example-control-button
         :ref 'finish-button :label "完成" :active nil
         :on-press #'etaf-animation-example--finish-edit)
        (etaf-animation-example-control-button
         :ref 'clear-button :label "清空" :active nil
         :on-press #'etaf-animation-example--clear-draft)
        (text :class "pad-hint" :if (>= (car (etaf-viewport)) 600)
              (expr (if (etaf-value etaf-animation-example-session)
                        "原生输入 / 选择 / 撤销 · C-c C-c 完成"
                      "点这里或「编辑」开始输入，动画继续在跑"))))
      (text :class "pad-text" :ref 'notepad
            (expr (etaf-value etaf-animation-example-draft))))
    (flex :class "footer" :ref 'footer :height '(lh 1) :flex-shrink 0 :overflow 'hidden :wrap-mode 'none
      (text :class "footer-shimmer"
            (expr (etaf-animation-example--shimmer
                   (etaf-value rail-tick) 30)))
      (text :class "footer-note"
            " one shared clock · animations never touch keys, focus, point or other buffers")))
  :styles
  (("&" :width stretch :height stretch :min-width (ch 28) :min-height (lh 20)
    :bgcolor (etaf-theme-token :bg) :color (etaf-theme-token :ink))
   (".rail" :bgcolor (etaf-theme-token :bar))
   (".rail-dim" :color (etaf-theme-token :dim)
    :background-color (etaf-theme-token :bar))
   (".rail-lit" :color (etaf-theme-token :accent) :font-weight bold
    :background-color (etaf-theme-token :bar))
   (".controls" :bgcolor (etaf-theme-token :bar)
    :padding-left (ch 1) :padding-right (px 0))
   (".controls-gap" :color (etaf-theme-token :bar))
   (".controls-state" :color (etaf-theme-token :dim) :font-size 0.85)
   (".panels" :margin-bottom (lh 1))
   (".pad" :bgcolor (etaf-theme-token :pad)
    :border-style solid :border-width (px 1)
    :border-color (etaf-theme-token :line)
    :padding-block (lh 0) :padding-left (ch 1) :padding-right (px 0)
    :margin-bottom (lh 1))
   (".pad-title" :color (etaf-theme-token :accent) :font-weight bold)
   (".pad-hint" :color (etaf-theme-token :dim) :font-size 0.85)
   (".pad-text" :color (etaf-theme-token :pad-ink))
   (".footer" :bgcolor (etaf-theme-token :bar))
   (".footer-shimmer" :color "#FBBF24")
   (".footer-note" :color (etaf-theme-token :dim) :font-size 0.85)))

(defun etaf-animation-example--fit-windows ()
  "Avoid a reserved truncation column in windows displaying this buffer."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (when (and (display-graphic-p (window-frame window))
               (zerop (nth 1 (window-fringes window))))
      ;; Non-persistent fringes reset when another buffer replaces the theatre.
      (set-window-fringes window (car (window-fringes window)) 1))))

;;;###autoload
(defun etaf-animation-example-view ()
  "Return the animation theatre View."
  (etaf-view (etaf-animation-example-theatre)))

;;;###autoload
(defun etaf-animation-example-open ()
  "Mount the animation theatre and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-animation-example-buffer-name
                            (etaf-animation-example-view))))
    (with-current-buffer buffer
      (add-hook 'window-configuration-change-hook
                #'etaf-animation-example--fit-windows nil t)
      (etaf-animation-example--fit-windows))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

(provide 'etaf-animation-example)
;;; etaf-animation-example.el ends here
