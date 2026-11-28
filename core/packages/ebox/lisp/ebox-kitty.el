;;; ebox-kitty.el --- Kitty terminal graphics protocol for Ebox -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Terminal image and live video streaming over the Kitty Graphics Protocol
;; using Unicode placeholders (U+10EEEE + row/column combining diacritics).
;;
;; Each cell in a prepared Kitty image grid is a single buffer space carrying a
;; composed U+10EEEE placeholder string in its `display' property, the 24-bit
;; image ID in its `:foreground' face attribute, and an `ebox-kitty-image'
;; marker property.  This integrates directly with Ebox's character-cell TTY
;; layout, line diffing, horizontal/vertical clipping, scrolling, hover and
;; modal backdrop composition without needing cursor-coordinate tracking hooks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar ebox-image-kitty-protocol 'auto
  "Control Kitty terminal graphics protocol use on text frames.
`auto' probes the terminal once and enables Unicode placeholder graphics
on compliant 24-bit terminals (such as Kitty 0.28+, Ghostty, Ghostel and
iTerm2 3.6+).  t enables transmission on any 24-bit text terminal that
acknowledges the Kitty graphics query.  nil disables the protocol so text
frames always fall back to `ebox-image-converters' or placeholders.")

(defconst ebox-kitty--placeholder #x10EEEE
  "Private-use Unicode codepoint used for Kitty image placeholder cells.")

(defconst ebox-kitty--diacritics
  [#x0305 #x030D #x030E #x0310 #x0312 #x033D #x033E #x033F
   #x0346 #x034A #x034B #x034C #x0350 #x0351 #x0352 #x0357
   #x035B #x0363 #x0364 #x0365 #x0366 #x0367 #x0368 #x0369
   #x036A #x036B #x036C #x036D #x036E #x036F #x0483 #x0484
   #x0485 #x0486 #x0487 #x0592 #x0593 #x0594 #x0595 #x0597
   #x0598 #x0599 #x059C #x059D #x059E #x059F #x05A0 #x05A1
   #x05A8 #x05A9 #x05AB #x05AC #x05AF #x05C4 #x0610 #x0611
   #x0612 #x0613 #x0614 #x0615 #x0616 #x0617 #x0657 #x0658
   #x0659 #x065A #x065B #x065D #x065E #x06D6 #x06D7 #x06D8
   #x06D9 #x06DA #x06DB #x06DC #x06DF #x06E0 #x06E1 #x06E2
   #x06E4 #x06E7 #x06E8 #x06EB #x06EC #x0730 #x0732 #x0733
   #x0735 #x0736 #x073A #x073D #x073F #x0740 #x0741 #x0743
   #x0745 #x0747 #x0749 #x074A #x07EB #x07EC #x07ED #x07EE
   #x07EF #x07F0 #x07F1 #x07F3 #x0816 #x0817 #x0818 #x0819
   #x081B #x081C #x081D #x081E #x081F #x0820 #x0821 #x0822
   #x0823 #x0825 #x0826 #x0827 #x0829 #x082A #x082B #x082C
   #x082D #x0951 #x0953 #x0954 #x0F82 #x0F83 #x0F86 #x0F87
   #x135D #x135E #x135F #x17DD #x193A #x1A17 #x1A75 #x1A76
   #x1A77 #x1A78 #x1A79 #x1A7A #x1A7B #x1A7C #x1B6B #x1B6D
   #x1B6E #x1B6F #x1B70 #x1B71 #x1B72 #x1B73 #x1CD0 #x1CD1
   #x1CD2 #x1CDA #x1CDB #x1CE0 #x1DC0 #x1DC1 #x1DC3 #x1DC4
   #x1DC5 #x1DC6 #x1DC7 #x1DC8 #x1DC9 #x1DCB #x1DCC #x1DD1
   #x1DD2 #x1DD3 #x1DD4 #x1DD5 #x1DD6 #x1DD7 #x1DD8 #x1DD9
   #x1DDA #x1DDB #x1DDC #x1DDD #x1DDE #x1DDF #x1DE0 #x1DE1
   #x1DE2 #x1DE3 #x1DE4 #x1DE5 #x1DE6 #x1DFE #x20D0 #x20D1
   #x20D4 #x20D5 #x20D6 #x20D7 #x20DB #x20DC #x20E1 #x20E7
   #x20E9 #x20F0 #x2CEF #x2CF0 #x2CF1 #x2DE0 #x2DE1 #x2DE2
   #x2DE3 #x2DE4 #x2DE5 #x2DE6 #x2DE7 #x2DE8 #x2DE9 #x2DEA
   #x2DEB #x2DEC #x2DED #x2DEE #x2DEF #x2DF0 #x2DF1 #x2DF2
   #x2DF3 #x2DF4 #x2DF5 #x2DF6 #x2DF7 #x2DF8 #x2DF9 #x2DFA
   #x2DFB #x2DFC #x2DFD #x2DFE #x2DFF #xA66F #xA67C #xA67D
   #xA6F0 #xA6F1 #xA8E0 #xA8E1 #xA8E2 #xA8E3 #xA8E4 #xA8E5
   #xA8E6 #xA8E7 #xA8E8 #xA8E9 #xA8EA #xA8EB #xA8EC #xA8ED
   #xA8EE #xA8EF #xA8F0 #xA8F1 #xAAB0 #xAAB2 #xAAB3 #xAAB7
   #xAAB8 #xAABE #xAABF #xAAC1 #xFE20 #xFE21 #xFE22 #xFE23
   #xFE24 #xFE25 #xFE26 #x10A0F #x10A38 #x1D185 #x1D186 #x1D187
   #x1D188 #x1D189 #x1D1AA #x1D1AB #x1D1AC #x1D1AD #x1D242 #x1D243
   #x1D244]
  "Canonical Kitty row/column combining diacritics (rowcolumn-diacritics.txt).")

(defconst ebox-kitty--png-signature "\x89PNG\r\n\x1a\n"
  "Eight-byte PNG file signature.")

(defconst ebox-kitty--chunk-size 4096
  "Maximum base64 payload bytes per Kitty direct-transfer chunk.")

(defconst ebox-kitty--probe-timeout 1.0
  "Maximum seconds to wait for a terminal Kitty graphics probe reply.
The loop exits immediately on the DA1 terminator, so responsive terminals
finish in a few milliseconds while busy startup sessions do not time out.")

(defconst ebox-kitty--default-cell-width 9
  "Fallback cell width in pixels when the terminal omits XTWINOPS 16t.")

(defconst ebox-kitty--default-cell-height 18
  "Fallback cell height in pixels when the terminal omits XTWINOPS 16t.")

(defconst ebox-kitty--max-raster-width 1920
  "Maximum pixel width used when rasterizing SVG or scaling images.")

(defconst ebox-kitty--max-raster-height 1080
  "Maximum pixel height used when rasterizing SVG or scaling images.")

(defconst ebox-kitty--temp-threshold 32768
  "Payload byte threshold above which local TTY transfers use temp files.")

(cl-defstruct (ebox-kitty--state (:constructor ebox-kitty--make-state)
                                 (:copier nil))
  "Per-terminal Kitty graphics capability and ID allocation state."
  probed ack version-string unicode-capable delete-before-replace
  cell-width cell-height local-fs tmux
  (next-seq 0)
  (live-ids (make-hash-table :test #'eql)))

(cl-defstruct (ebox-kitty--stream (:constructor ebox-kitty--make-stream)
                                  (:copier nil))
  "Reusable Kitty virtual placement stream for live frame presentation."
  terminal image-id columns rows grid local-fs tmux delete-before-replace
  destroyed
  (seq 0))

;;;; Terminal transport and capability probing

(defun ebox-kitty--wrap-tmux (sequence)
  "Wrap escape SEQUENCE in tmux DCS passthrough."
  (concat "\ePtmux;"
          (string-replace "\e" "\e\e" sequence)
          "\e\\"))

(defun ebox-kitty--send (sequence terminal &optional tmux)
  "Send escape SEQUENCE to TERMINAL, wrapping for TMUX when non-nil."
  (when (and terminal (terminal-live-p terminal))
    (send-string-to-terminal
     (if tmux (ebox-kitty--wrap-tmux sequence) sequence)
     terminal)))

(defun ebox-kitty--local-fs-p ()
  "Return non-nil when the terminal likely shares the local filesystem."
  (not (or (getenv "SSH_TTY")
           (getenv "SSH_CONNECTION")
           (getenv "SSH_CLIENT"))))

(defun ebox-kitty--tmux-p ()
  "Return non-nil when Emacs runs inside a tmux session."
  (let ((tmux (getenv "TMUX")))
    (and (stringp tmux) (not (string-empty-p tmux)))))

(defun ebox-kitty--iterm2-p (version-string)
  "Return non-nil when VERSION-STRING or environment identifies iTerm2."
  (let ((ver (downcase (or version-string "")))
        (prog (downcase (or (getenv "TERM_PROGRAM") ""))))
    (or (string-match-p "iterm2" ver)
        (and (string-empty-p ver) (string= prog "iterm.app")))))

(defun ebox-kitty--unicode-terminal-p (version-string)
  "Return non-nil when VERSION-STRING or environment indicates U=1 support.
Kitty 0.28+, Ghostty, Ghostel and iTerm2 3.6+ implement Kitty Unicode
placeholders."
  (let* ((ver (or version-string ""))
         (down (downcase ver)))
    (or
     ;; Kitty reports "kitty(0.46.1)" or "kitty 0.46.1"
     (and (string-match "kitty[( ]+\\([0-9]+\\)\\.\\([0-9]+\\)" down)
          (let ((major (string-to-number (match-string 1 down)))
                (minor (string-to-number (match-string 2 down))))
            (or (> major 0) (>= minor 28))))
     ;; Ghostty / libghostty-vt (Ghostel)
     (string-match-p "\\(?:ghostty\\|ghostel\\)" down)
     ;; iTerm2 3.6+ reports "iTerm2 3.6.9"
     (and (string-match "iterm2[ /]+\\([0-9]+\\)\\.\\([0-9]+\\)" down)
          (let ((major (string-to-number (match-string 1 down)))
                (minor (string-to-number (match-string 2 down))))
            (or (> major 3) (and (= major 3) (>= minor 6)))))
     ;; Fallback when XTVERSION is intercepted (for example inside tmux)
     (and (string-empty-p ver)
          (let ((term (or (getenv "TERM") ""))
                (prog (downcase (or (getenv "TERM_PROGRAM") "")))
                (prog-ver (or (getenv "TERM_PROGRAM_VERSION") "")))
            (or (and (getenv "KITTY_WINDOW_ID")
                     (not (string-empty-p (getenv "KITTY_WINDOW_ID"))))
                (and (getenv "GHOSTTY_RESOURCES_DIR")
                     (not (string-empty-p (getenv "GHOSTTY_RESOURCES_DIR"))))
                (string-match-p "kitty\\|ghostty" term)
                (member prog '("kitty" "ghostty"))
                (and (string= prog "iterm.app")
                     (string-match "\\`\\([0-9]+\\)\\.\\([0-9]+\\)" prog-ver)
                     (let ((major (string-to-number (match-string 1 prog-ver)))
                           (minor (string-to-number (match-string 2 prog-ver))))
                       (or (> major 3)
                           (and (= major 3) (>= minor 6)))))))))))

(defun ebox-kitty--state (terminal)
  "Return or initialize TERMINAL's Kitty state record."
  (or (terminal-parameter terminal 'ebox-kitty--state)
      (let ((state (ebox-kitty--make-state
                    :local-fs (ebox-kitty--local-fs-p)
                    :tmux (ebox-kitty--tmux-p))))
        (set-terminal-parameter terminal 'ebox-kitty--state state)
        state)))

(defun ebox-kitty--read-escape (deadline)
  "Consume one complete terminal escape sequence starting after ESC.
DEADLINE is a `float-time' cap.  Return the complete sequence string
\(including the leading ESC), or nil when no follow-up character arrives
within a short inter-byte timeout (indicating a standalone Escape key)."
  (let ((next (read-event nil nil (min 0.03 (max 0.005 (- deadline (float-time)))))))
    (cond
     ((not (characterp next))
      (when next
        (push next unread-command-events))
      nil)
     ;; CSI: ESC [ params... final (0x40..0x7E)
     ((eq next ?\[)
      (let ((chars (list next ?\e))
            (done nil))
        (while (and (not done) (< (float-time) deadline))
          (let ((ch (read-event nil nil (min 0.04 (max 0.005 (- deadline (float-time)))))))
            (if (not (characterp ch))
                (progn
                  (when ch (push ch unread-command-events))
                  (setq done t))
              (push ch chars)
              (when (and (>= ch #x40) (<= ch #x7E))
                (setq done t)))))
        (apply #'string (nreverse chars))))
     ;; APC (ESC _), DCS (ESC P), OSC (ESC ]): terminated by ST (ESC \) or BEL
     ((memq next '(?_ ?P ?\]))
      (let ((chars (list next ?\e))
            (osc (eq next ?\]))
            (prev-esc nil)
            (done nil))
        (while (and (not done) (< (float-time) deadline))
          (let ((ch (read-event nil nil (min 0.04 (max 0.005 (- deadline (float-time)))))))
            (if (not (characterp ch))
                (progn
                  (when ch (push ch unread-command-events))
                  (setq done t))
              (push ch chars)
              (cond
               ((and prev-esc (eq ch ?\\))
                (setq done t))
               ((and osc (eq ch ?\a))
                (setq done t))
               (t
                (setq prev-esc (eq ch ?\e)))))))
        (apply #'string (nreverse chars))))
     ;; SS3 (ESC O <ch>) or two-byte escape
     ((eq next ?O)
      (let ((ch (read-event nil nil (min 0.02 (max 0.005 (- deadline (float-time)))))))
        (if (characterp ch)
            (string ?\e next ch)
          (when ch (push ch unread-command-events))
          (string ?\e next))))
     (t
      (string ?\e next)))))

(defun ebox-kitty--probe-terminal (frame)
  "Actively probe FRAME's text terminal once for Kitty graphics capabilities.
Sends a single round-trip containing a Kitty 1x1 query (`a=q'), XTVERSION
(`CSI > 0 q'), cell/window pixel sizes (`CSI 16 t', `CSI 14 t', `CSI 18 t'),
DSR (`CSI 5 n') and DA1 (`CSI c').  Complete escape sequences are consumed
atomically so concurrent focus or SGR mouse reports cannot split across the
probe boundary and leak stray text into buffers."
  (let* ((terminal (frame-terminal frame))
         (state (ebox-kitty--state terminal)))
    (unless (ebox-kitty--state-probed state)
      (setf (ebox-kitty--state-probed state) t)
      (when (and (not noninteractive)
                 (not (display-graphic-p frame))
                 (terminal-live-p terminal)
                 (eq terminal (frame-terminal (selected-frame))))
        (let* ((tmux (ebox-kitty--state-tmux state))
               (kitty-q "\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\")
               (query (concat (if tmux (ebox-kitty--wrap-tmux kitty-q) kitty-q)
                              "\e[>0q\e[16t\e[14t\e[18t\e[5n\e[c"))
               (buf "")
               (done nil)
               (saved nil)
               (dsr-seen nil)
               (da1-seen nil)
               (deadline (+ (float-time) ebox-kitty--probe-timeout)))
          ;; Drain any already-queued events before probing.  Consume pending
          ;; terminal escape sequences cleanly (never push raw ESC bytes into
          ;; `unread-command-events', where Emacs skips `input-decode-map' and
          ;; would insert stray `[I' or `;...M' fragments into buffers).
          (let ((pre (read-event nil nil 0)))
            (while pre
              (if (eq pre ?\e)
                  (unless (ebox-kitty--read-escape (+ (float-time) 0.05))
                    (push pre saved))
                (push pre saved))
              (setq pre (read-event nil nil 0))))
          (send-string-to-terminal query terminal)
          (while (and (not done) (< (float-time) deadline))
            (let ((ev (read-event nil nil (if da1-seen 0.04 0.05))))
              (cond
               ((null ev)
                (when da1-seen
                  (setq done t)))
               ((eq ev ?\e)
                (let ((seq (ebox-kitty--read-escape deadline)))
                  (if (null seq)
                      (push ev saved)
                    (setq buf (concat buf seq))
                    (cond
                     ((string= seq "\e[0n")
                      (setq dsr-seen t))
                     ((string-match-p "\\`\e\\[\\?[0-9;]*c\\'" seq)
                      (setq da1-seen t)
                      (when dsr-seen
                        (setq done t)))))))
               (t
                (push ev saved)))))
          (when saved
            (setq unread-command-events
                  (append (nreverse saved) unread-command-events)))
          (let ((ack (and (string-match-p "\e_Gi=31;OK\e\\\\" buf) t))
                (ver (when (string-match "\eP>|\\([^\e]*\\)\e\\\\" buf)
                       (match-string 1 buf)))
                (cell-w nil)
                (cell-h nil))
            (cond
             ((string-match "\e\\[6;\\([0-9]+\\);\\([0-9]+\\)t" buf)
              (let ((h (string-to-number (match-string 1 buf)))
                    (w (string-to-number (match-string 2 buf))))
                (when (and (> w 0) (> h 0))
                  (setq cell-w w cell-h h))))
             ((and (string-match "\e\\[4;\\([0-9]+\\);\\([0-9]+\\)t" buf)
                   (let ((wh (string-to-number (match-string 1 buf)))
                         (ww (string-to-number (match-string 2 buf))))
                     (and (> ww 0) (> wh 0)
                          (string-match "\e\\[8;\\([0-9]+\\);\\([0-9]+\\)t" buf)
                          (let ((rows (string-to-number (match-string 1 buf)))
                                (cols (string-to-number (match-string 2 buf))))
                            (when (and (> cols 0) (> rows 0))
                              (setq cell-w (max 1 (round ww cols))
                                    cell-h (max 1 (round wh rows)))
                              t)))))))
            (setf (ebox-kitty--state-ack state) ack
                  (ebox-kitty--state-version-string state) ver
                  (ebox-kitty--state-unicode-capable state)
                  (and ack (ebox-kitty--unicode-terminal-p ver))
                  (ebox-kitty--state-delete-before-replace state)
                  (ebox-kitty--iterm2-p ver)
                  (ebox-kitty--state-cell-width state) cell-w
                  (ebox-kitty--state-cell-height state) cell-h)))))
    state))

(defun ebox-kitty--capabilities (&optional frame)
  "Return Kitty capability plist for FRAME, or nil when unavailable.
The plist contains `:terminal', `:cell-width', `:cell-height', `:local',
`:tmux' and `:delete-before-replace'."
  (let* ((frame (or frame (selected-frame)))
         (mode ebox-image-kitty-protocol))
    (when (and mode
               (not noninteractive)
               (frame-live-p frame)
               (not (display-graphic-p frame))
               (>= (display-color-cells frame) 16777216))
      (let* ((terminal (frame-terminal frame))
             (state (ebox-kitty--probe-terminal frame))
             (enabled (cond
                       ((eq mode 'auto)
                        (ebox-kitty--state-unicode-capable state))
                       (t
                        (ebox-kitty--state-ack state)))))
        (when enabled
          (list :terminal terminal
                :cell-width (or (ebox-kitty--state-cell-width state)
                                ebox-kitty--default-cell-width)
                :cell-height (or (ebox-kitty--state-cell-height state)
                                 ebox-kitty--default-cell-height)
                :local (and (ebox-kitty--state-local-fs state) t)
                :tmux (and (ebox-kitty--state-tmux state) t)
                :delete-before-replace
                (and (ebox-kitty--state-delete-before-replace state) t)))))))

(defun ebox-image-kitty-available-p (&optional frame)
  "Return a capability plist when FRAME supports Kitty terminal graphics.
FRAME defaults to the selected frame.  Return nil in batch sessions, on
graphical frames, when `ebox-image-kitty-protocol' is nil, or when FRAME's
terminal lacks 24-bit color or Kitty Unicode placeholder support.
When non-nil, the fresh plist holds `:cell-width', `:cell-height' and
`:local' (whether local file transfers are available)."
  (when-let* ((caps (ebox-kitty--capabilities frame)))
    (list :cell-width (plist-get caps :cell-width)
          :cell-height (plist-get caps :cell-height)
          :local (plist-get caps :local))))

;;;; Image ID allocation and cleanup

(defun ebox-kitty--alloc-id (terminal)
  "Allocate a fresh 24-bit Kitty image ID scoped to this Emacs process."
  (let* ((state (ebox-kitty--state terminal))
         (seq (1+ (ebox-kitty--state-next-seq state)))
         (seq (if (> seq #xFFFF) 1 seq))
         (prefix (1+ (logand (emacs-pid) #x7F)))
         (id (logior (ash prefix 16) seq)))
    (setf (ebox-kitty--state-next-seq state) seq)
    (puthash id t (ebox-kitty--state-live-ids state))
    id))

(defun ebox-kitty--delete-id (terminal image-id &optional tmux)
  "Delete IMAGE-ID and its pixel data from TERMINAL."
  (when (and terminal (terminal-live-p terminal)
             (integerp image-id) (> image-id 0))
    (let ((state (terminal-parameter terminal 'ebox-kitty--state)))
      (when state
        (remhash image-id (ebox-kitty--state-live-ids state))
        (setq tmux (or tmux (ebox-kitty--state-tmux state)))))
    (ebox-kitty--send (format "\e_Ga=d,d=I,i=%d,q=2\e\\" image-id)
                      terminal tmux)))

(defun ebox-kitty--on-delete-terminal (terminal)
  "Release tracked Kitty state when TERMINAL closes."
  (when-let* ((state (terminal-parameter terminal 'ebox-kitty--state)))
    (clrhash (ebox-kitty--state-live-ids state))
    (set-terminal-parameter terminal 'ebox-kitty--state nil)))

(add-hook 'delete-terminal-functions #'ebox-kitty--on-delete-terminal)

;;;; Payload encoding and transmission

(defun ebox-kitty--png-bytes-p (bytes)
  "Return non-nil when unibyte string BYTES begins with a PNG signature."
  (and (stringp bytes)
       (>= (length bytes) 8)
       (string-prefix-p ebox-kitty--png-signature bytes)))

(defun ebox-kitty--file-png-p (file)
  "Return non-nil when regular readable FILE has a PNG signature."
  (and (stringp file)
       (file-regular-p file)
       (file-readable-p file)
       (condition-case nil
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file nil 0 8)
             (ebox-kitty--png-bytes-p (buffer-string)))
         (error nil))))

(defun ebox-kitty--svg-source-p (source bytes)
  "Return non-nil when SOURCE or BYTES appears to be an SVG document."
  (or (and (consp source) (eq (plist-get (cdr source) :type) 'svg))
      (and (stringp source)
           (string-match-p "\\.svgz?\\'" (downcase source)))
      (and (consp source)
           (stringp (plist-get (cdr source) :file))
           (string-match-p "\\.svgz?\\'"
                           (downcase (plist-get (cdr source) :file))))
      (and (stringp bytes)
           (let ((head (substring bytes 0 (min 512 (length bytes)))))
             (string-match-p "<svg\\b" head)))))

(defun ebox-kitty--run-converter (program args input-bytes)
  "Run PROGRAM with ARGS, optionally feeding INPUT-BYTES on stdin.
Return unibyte stdout bytes on exit 0, or nil."
  (when-let* ((exe (executable-find program)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let* ((coding-system-for-read 'binary)
             (coding-system-for-write 'binary)
             (status
              (if input-bytes
                  (progn
                    (insert input-bytes)
                    (apply #'call-process-region (point-min) (point-max)
                           exe t (list t nil) nil args))
                (apply #'call-process exe nil (list t nil) nil args))))
        (when (eql status 0)
          (buffer-string))))))

(defun ebox-kitty--rasterize-svg (file bytes max-w max-h)
  "Rasterize SVG from FILE or BYTES to PNG bytes fitting MAX-W by MAX-H."
  (let ((w (number-to-string max-w))
        (h (number-to-string max-h)))
    (or
     ;; rsvg-convert preserves alpha and aspect ratio cleanly.
     (let ((out (ebox-kitty--run-converter
                 "rsvg-convert"
                 (append (list "-w" w "-h" h "--keep-aspect-ratio" "-f" "png")
                         (unless bytes (list file)))
                 bytes)))
       (and (ebox-kitty--png-bytes-p out) out))
     ;; ImageMagick 7 (`magick') or 6 (`convert').
     (cl-loop for bin in '("magick" "convert")
              for out = (ebox-kitty--run-converter
                         bin
                         (list "-background" "none"
                               (if bytes "svg:-" file)
                               "-resize" (format "%sx%s>" w h)
                               "png:-")
                         bytes)
              when (ebox-kitty--png-bytes-p out)
              return out))))

(defun ebox-kitty--convert-to-png (file bytes max-w max-h)
  "Convert raster image FILE or BYTES to PNG bytes fitting MAX-W by MAX-H."
  (let ((scale (format "scale='min(iw,%d)':'min(ih,%d)':force_original_aspect_ratio=decrease"
                       max-w max-h)))
    (or
     ;; ffmpeg handles JPEG, WebP, GIF, TIFF, BMP, PNM from file or pipe.
     (let ((out (ebox-kitty--run-converter
                 "ffmpeg"
                 (list "-v" "error" "-nostdin"
                       "-i" (if bytes "-" file)
                       "-vf" scale
                       "-frames:v" "1" "-f" "image2pipe" "-vcodec" "png" "pipe:1")
                 bytes)))
       (and (ebox-kitty--png-bytes-p out) out))
     ;; ImageMagick fallback.
     (cl-loop for bin in '("magick" "convert")
              for out = (ebox-kitty--run-converter
                         bin
                         (list (if bytes "-" (concat file "[0]"))
                               "-resize" (format "%dx%d>" max-w max-h)
                               "png:-")
                         bytes)
              when (ebox-kitty--png-bytes-p out)
              return out)
     ;; macOS built-in sips fallback for local files.
     (when (and file (null bytes) (eq system-type 'darwin) (executable-find "sips"))
       (let ((tmp (make-temp-file "ebox-kitty-sips-" nil ".png")))
         (unwind-protect
             (when (eql 0 (call-process "sips" nil nil nil
                                        "-s" "format" "png"
                                        "-Z" (number-to-string (max max-w max-h))
                                        file "--out" tmp))
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally tmp)
                 (let ((out (buffer-string)))
                   (and (ebox-kitty--png-bytes-p out) out))))
           (ignore-errors (delete-file tmp))))))))

(defun ebox-kitty--write-temp-payload (bytes)
  "Write unibyte BYTES to a Kitty-deletable temp file and return its path.
Kitty only unlinks `t=t' files whose full path contains the substring
`tty-graphics-protocol' inside a standard temp directory."
  (let ((file (make-temp-file "tty-graphics-protocol-ebox-"))
        (coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert bytes)
      (write-region (point-min) (point-max) file nil 'silent))
    file))

(defun ebox-kitty--transmit-direct (terminal tmux header bytes)
  "Transmit unibyte BYTES in 4096-byte base64 chunks with HEADER."
  (let* ((encoded (base64-encode-string bytes t))
         (total (length encoded))
         (offset 0)
         (first t))
    (if (= total 0)
        (ebox-kitty--send (format "\e_G%s,m=0;\e\\" header) terminal tmux)
      (while (< offset total)
        (let* ((end (min total (+ offset ebox-kitty--chunk-size)))
               (more (if (< end total) 1 0))
               (chunk (substring encoded offset end))
               (ctrl (if first
                         (format "%s,m=%d" header more)
                       (format "m=%d,q=2" more))))
          (ebox-kitty--send (format "\e_G%s;%s\e\\" ctrl chunk) terminal tmux)
          (setq offset end first nil))))))

(defun ebox-kitty--transmit-virtual (terminal tmux local-fs id cols rows
                                              fmt width height payload-kind payload
                                              &optional delete-first)
  "Transmit image ID and create a COLS by ROWS virtual placement (U=1).
FMT is 100 (PNG), 24 (RGB24) or 32 (RGBA32).  WIDTH and HEIGHT are required
when FMT is 24 or 32.  PAYLOAD-KIND is `file' (`t=f'), `temp' (`t=t'), or
`bytes' (`t=d' or auto-promoted to `t=t' for large local payloads).  When
DELETE-FIRST is non-nil, prepend a quiet delete of ID in the same write so
terminals that cache prior IDs (such as iTerm2) repaint the replacement."
  (let* ((dims (if (memq fmt '(24 32))
                   (format ",s=%d,v=%d" width height)
                 ""))
         (base (format "a=T,f=%d%s,i=%d,U=1,c=%d,r=%d,q=2"
                       fmt dims id cols rows))
         (del (when delete-first
                (let ((seq (format "\e_Ga=d,d=I,i=%d,q=2\e\\" id)))
                  (if tmux (ebox-kitty--wrap-tmux seq) seq))))
         (send-single
          (lambda (seq)
            (when (and terminal (terminal-live-p terminal))
              (let ((body (if tmux (ebox-kitty--wrap-tmux seq) seq)))
                (send-string-to-terminal (if del (concat del body) body)
                                         terminal))))))
    (cond
     ((and (eq payload-kind 'file) local-fs (stringp payload))
      (let ((path-b64 (base64-encode-string (encode-coding-string payload 'utf-8) t)))
        (funcall send-single (format "\e_G%s,t=f;%s\e\\" base path-b64))))
     ((and (eq payload-kind 'temp) local-fs (stringp payload))
      (let ((path-b64 (base64-encode-string (encode-coding-string payload 'utf-8) t)))
        (funcall send-single (format "\e_G%s,t=t;%s\e\\" base path-b64))))
     ((and (eq payload-kind 'bytes) local-fs
           (> (length payload) ebox-kitty--temp-threshold))
      (let* ((tmp (ebox-kitty--write-temp-payload payload))
             (path-b64 (base64-encode-string (encode-coding-string tmp 'utf-8) t)))
        (funcall send-single (format "\e_G%s,t=t;%s\e\\" base path-b64))))
     (t
      (when (and del terminal (terminal-live-p terminal))
        (send-string-to-terminal del terminal))
      (ebox-kitty--transmit-direct terminal tmux (concat base ",t=d") payload)))))

;;;; Unicode placeholder grid construction

(defun ebox-kitty--id-color (image-id)
  "Encode 24-bit IMAGE-ID as an Emacs `#RRGGBB' foreground color string."
  (format "#%02x%02x%02x"
          (logand (ash image-id -16) #xFF)
          (logand (ash image-id -8) #xFF)
          (logand image-id #xFF)))

(defun ebox-kitty--grid (image-id columns rows)
  "Build a COLUMNS by ROWS Kitty Unicode placeholder grid for IMAGE-ID.
Each cell is a single space carrying a composed U+10EEEE + row/column/MSB
diacritic string in its `display' property, the encoded 24-bit IMAGE-ID in
its `:foreground' face attribute, and `ebox-kitty-image' set to IMAGE-ID.
Including the explicit third diacritic (MSB = 0, U+0305) follows the Kitty
specification and is required by iTerm2 3.6+ when placement ID is omitted."
  (let* ((limit (length ebox-kitty--diacritics))
         (msb-d (aref ebox-kitty--diacritics 0))
         (fg (ebox-kitty--id-color image-id))
         (face (list :foreground fg)))
    (when (or (> columns limit) (> rows limit))
      (error "Kitty image grid %dx%d exceeds diacritic limit %d"
             columns rows limit))
    (mapconcat
     (lambda (row)
       (let ((row-d (aref ebox-kitty--diacritics row))
             (line (make-string columns ?\s)))
         (dotimes (col columns)
           (let ((glyph (compose-string
                         (string ebox-kitty--placeholder
                                 row-d
                                 (aref ebox-kitty--diacritics col)
                                 msb-d))))
             (add-text-properties
              col (1+ col)
              (list 'display glyph
                    'face face
                    'ebox-kitty-image image-id)
              line)))
         line))
     (number-sequence 0 (1- rows))
     "\n")))

;;;; Static image preparation entry point (called by ebox-image.el)

(defun ebox-kitty--prepare (source columns rows frame)
  "Prepare SOURCE as a COLUMNS by ROWS Kitty placeholder grid on FRAME.
Return the propertized grid string on success, or nil to decline cleanly."
  (let ((caps (ebox-kitty--capabilities frame)))
    (when (and caps
               (<= columns (length ebox-kitty--diacritics))
               (<= rows (length ebox-kitty--diacritics))
               (not (and (consp source)
                         (eq (plist-get (cdr source) :type) 'canvas))))
      (let* ((terminal (plist-get caps :terminal))
             (local-fs (plist-get caps :local))
             (tmux (plist-get caps :tmux))
             (cell-w (plist-get caps :cell-width))
             (cell-h (plist-get caps :cell-height))
             ;; Terminals reporting logical points (e.g. iTerm2 CSI 14t) report
             ;; ~8x19; scale rasterization by 2x for crisp HiDPI rendering.
             (raster-scale (if (< cell-w 12) 2 1))
             (max-w (min ebox-kitty--max-raster-width
                         (max 1 (* columns cell-w raster-scale))))
             (max-h (min ebox-kitty--max-raster-height
                         (max 1 (* rows cell-h raster-scale))))
             (file (cond ((stringp source) source)
                         ((consp source) (plist-get (cdr source) :file))))
             (raw-data (and (consp source) (plist-get (cdr source) :data)))
             (data (and raw-data
                        (if (multibyte-string-p raw-data)
                            (encode-coding-string raw-data 'utf-8-unix)
                          raw-data)))
             (payload-kind nil)
             (payload nil))
        (cond
         ;; Fast path 1: local regular PNG file over shared filesystem.
         ((and (null data) file local-fs (ebox-kitty--file-png-p file))
          (setq payload-kind 'file payload file))
         ;; Fast path 2: in-memory PNG bytes or remote PNG file.
         ((and data (ebox-kitty--png-bytes-p data))
          (setq payload-kind 'bytes payload data))
         ((and (null data) file (ebox-kitty--file-png-p file))
          (setq payload-kind 'bytes
                payload (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally file)
                          (buffer-string))))
         ;; SVG rasterization (Mermaid, MathJax, vector icons, avatars).
         ((and (or data (and file (file-readable-p file)))
               (ebox-kitty--svg-source-p source data))
          (when-let* ((png (ebox-kitty--rasterize-svg file data max-w max-h)))
            (setq payload-kind 'bytes payload png)))
         ;; Other raster formats (JPEG, WebP, GIF, TIFF, BMP, etc.).
         ((or data (and file (file-readable-p file)))
          (when-let* ((png (ebox-kitty--convert-to-png file data max-w max-h)))
            (setq payload-kind 'bytes payload png))))
        (when (and payload-kind payload)
          (let ((id (ebox-kitty--alloc-id terminal)))
            (ebox-kitty--transmit-virtual
             terminal tmux local-fs id columns rows 100 nil nil
             payload-kind payload)
            (ebox-kitty--grid id columns rows)))))))

;;;; Live frame streaming public API (for video and real-time canvases)

(defun ebox-image-kitty-stream-create (columns rows &optional frame)
  "Create a Kitty virtual placement stream for COLUMNS by ROWS cells on FRAME.
Return an opaque stream handle, or nil when FRAME does not support Kitty
terminal graphics.  Write the placeholder grid from
`ebox-image-kitty-stream-grid' into the buffer once, push new frames in
place with `ebox-image-kitty-stream-present', and free terminal resources
with `ebox-image-kitty-stream-destroy'."
  (unless (and (integerp columns) (> columns 0)
               (integerp rows) (> rows 0))
    (error "Ebox Kitty stream columns and rows must be positive integers"))
  (let ((limit (length ebox-kitty--diacritics)))
    (when (or (> columns limit) (> rows limit))
      (error "Ebox Kitty stream %dx%d exceeds diacritic limit %d"
             columns rows limit)))
  (when-let* ((caps (ebox-kitty--capabilities frame)))
    (let* ((terminal (plist-get caps :terminal))
           (id (ebox-kitty--alloc-id terminal))
           (grid (ebox-kitty--grid id columns rows)))
      (ebox-kitty--make-stream
       :terminal terminal
       :image-id id
       :columns columns
       :rows rows
       :grid grid
       :local-fs (plist-get caps :local)
       :tmux (plist-get caps :tmux)
       :delete-before-replace (plist-get caps :delete-before-replace)))))

(defun ebox-image-kitty-stream-grid (stream)
  "Return an owned placeholder grid string for Kitty STREAM."
  (unless (ebox-kitty--stream-p stream)
    (error "Expected a stream from ebox-image-kitty-stream-create"))
  (copy-sequence (ebox-kitty--stream-grid stream)))

(defun ebox-image-kitty-stream-present (stream bytes width height &optional format)
  "Present one frame of BYTES (WIDTH by HEIGHT) into Kitty STREAM in place.
FORMAT is `rgb24' (default), `rgba32' or `png'.  On local terminals this
transfers the frame through an auto-deleted temp file (`t=t'); over remote
connections it uses chunked direct transfer (`t=d').  The terminal updates
the already-displayed placeholder cells without modifying any Emacs buffer.
Return non-nil when the frame was transmitted, or nil if STREAM was destroyed
or its terminal is no longer live."
  (unless (ebox-kitty--stream-p stream)
    (error "Expected a stream from ebox-image-kitty-stream-create"))
  (unless (and (stringp bytes) (not (multibyte-string-p bytes)))
    (error "Ebox Kitty stream frame bytes must be a unibyte string"))
  (unless (and (integerp width) (> width 0) (integerp height) (> height 0))
    (error "Ebox Kitty stream frame width and height must be positive integers"))
  (let* ((fmt (or format 'rgb24))
         (code (pcase fmt
                 ('rgb24 24)
                 ('rgba32 32)
                 ('png 100)
                 (_ (error "Unsupported Ebox Kitty stream format: %S" fmt)))))
    (when (eq fmt 'rgb24)
      (unless (= (length bytes) (* width height 3))
        (error "Expected %d RGB24 bytes for %dx%d frame, got %d"
               (* width height 3) width height (length bytes))))
    (when (eq fmt 'rgba32)
      (unless (= (length bytes) (* width height 4))
        (error "Expected %d RGBA32 bytes for %dx%d frame, got %d"
               (* width height 4) width height (length bytes))))
    (let ((terminal (ebox-kitty--stream-terminal stream)))
      (when (and (not (ebox-kitty--stream-destroyed stream))
                 (terminal-live-p terminal))
        (let ((local-fs (ebox-kitty--stream-local-fs stream))
              (tmux (ebox-kitty--stream-tmux stream))
              (id (ebox-kitty--stream-image-id stream))
              (cols (ebox-kitty--stream-columns stream))
              (rows (ebox-kitty--stream-rows stream))
              (delete-first (and (ebox-kitty--stream-delete-before-replace stream)
                                 (> (ebox-kitty--stream-seq stream) 0))))
          (cl-incf (ebox-kitty--stream-seq stream))
          (if local-fs
              (let ((tmp (ebox-kitty--write-temp-payload bytes)))
                (ebox-kitty--transmit-virtual
                 terminal tmux t id cols rows code width height 'temp tmp
                 delete-first))
            (ebox-kitty--transmit-virtual
             terminal tmux nil id cols rows code width height 'bytes bytes
             delete-first))
          t)))))

(defun ebox-image-kitty-stream-destroy (stream)
  "Destroy Kitty STREAM and release its image data on its terminal."
  (unless (ebox-kitty--stream-p stream)
    (error "Expected a stream from ebox-image-kitty-stream-create"))
  (unless (ebox-kitty--stream-destroyed stream)
    (setf (ebox-kitty--stream-destroyed stream) t)
    (ebox-kitty--delete-id (ebox-kitty--stream-terminal stream)
                           (ebox-kitty--stream-image-id stream)
                           (ebox-kitty--stream-tmux stream)))
  nil)

(provide 'ebox-kitty)
;;; ebox-kitty.el ends here
