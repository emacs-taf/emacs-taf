;;; etaf-ncm-app.el --- Application shell of the NetEase Cloud Music player -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The application layer binds one player model to the Views.  `etaf-ncm-app'
;; is the only place that reads the model's reactive sources, so a backend
;; reply or a key press repaints the whole player in one place, and it owns the
;; session lifecycle: the palette is provided for its subtree, playback polling
;; starts on mount, and the session's timer and in-flight requests are released
;; on unmount.
;;
;; Every key is a `:keys' binding of the View, so an embedded player keeps them
;; and `?' lists them in ETAF's read-only help modal.  `etaf-ncm-open' adds what a
;; Component cannot own by itself: the buffer name, the wheel bindings and the
;; window-fitting page size.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ncm-theme)
(require 'etaf-ncm-service)
(require 'etaf-ncm-model)
(require 'etaf-ncm-hero)
(require 'etaf-ncm-meter)
(require 'etaf-ncm-views)

(declare-function etaf-ncm-doctor "etaf-ncm" ())

;;; ---------------------------------------------------------------------------
;;; Buffer state and wheel bindings
;;; ---------------------------------------------------------------------------

(defcustom etaf-ncm-buffer-name "*ETAF 网易云音乐*"
  "Buffer opened by `etaf-ncm-open'."
  :type 'string
  :group 'etaf-ncm)

(defvar etaf-ncm--model nil
  "Player model a key command acts on.
Key commands bind it to their session, so an embedded player shares the
buffer-free commands; other commands use the opened player's state.")

(defun etaf-ncm--current-model ()
  "Return the model of the current player buffer."
  (or etaf-ncm--model
      (etaf-app-state)
      (user-error "Current buffer is not an etaf-ncm player")))

;;; ---------------------------------------------------------------------------
;;; Model to View projections
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--view-entries (model)
  "Return MODEL's visible library rows as list entries."
  (pcase-let* ((`(,rows ,start ,_total) (etaf-ncm--page-rows model))
               (playing (plist-get (etaf-ncm--read model :status) :song-id)))
    (cl-loop for row in rows
             for index from start
             collect (list :index (1+ index)
                           :row row
                           :playing (and playing
                                         (eq (plist-get row :kind) :song)
                                         (equal (plist-get row :id) playing))))))

(defun etaf-ncm--view-status (model)
  "Return MODEL's playback status, or an empty status plist."
  (let ((status (or (etaf-ncm--read model :status)
                    (list :state 'idle :duration 0 :volume 0
                          :queue-pos 0 :queue-count 0 :shuffle nil :repeat nil))))
    (plist-put (copy-sequence status) :elapsed (etaf-ncm--clock model))))

(defun etaf-ncm--status-source (model key)
  "Return a retained projection of MODEL's status field KEY."
  (etaf-computed (lambda () (plist-get (etaf-ncm--read model :status) key))
                 :test #'equal :name (intern (format "ncm-status-%s" key))))

;;;###autoload
(defun etaf-ncm--lyric-panel (model &optional budget)
  "Return MODEL's lyric window as props for the lyrics View.
BUDGET is how many rows to show; it defaults to the aside panel's lyric rows,
so the full-page view can ask for its own taller window.
Each visible line is (SECONDS TEXT ORDINAL); the ordinal is its position in
the parsed lyric, so the View keeps one stable key per line even when a real
LRC repeats a timestamp."
  (let* ((lyric (etaf-ncm--read model :lyric))
         (lines (plist-get lyric :lines))
         (budget (or budget (etaf-ncm--read model :lyric-rows)))
         (trans (and (> budget 1) (plist-get lyric :trans)))
         (size (if trans (/ budget 2) budget))
         (elapsed (etaf-ncm--read model :position-ref))
         (index (and lines (etaf-ncm--lyric-index lines elapsed)))
         (window (and lines
                      (etaf-ncm--lyric-window lines index size)))
         (start (car window))
         (visible (cl-loop for line in (cdr window)
                           for ordinal from start
                           collect (list (car line) (cdr line) ordinal)))
         (cells (if visible
                    (cl-loop for line in visible
                             append (append (list (list :text (etaf-ncm--fold-joiners
                                                                 (nth 1 line))
                                                        :current (equal (car line) (car (nth index lines)))))
                                            (when-let* ((translation (cl-assoc (car line) trans :test #'=)))
                                              (list (list :text (etaf-ncm--fold-joiners
                                                                 (cdr translation))
                                                          :translation t)))))
                  (list (list :text (if (plist-get lyric :loading) "正在取歌词..." "这首歌没有歌词")))))
         ;; Pad the window to its full budget so a short lyric sits as one
         ;; centred block: a card, a short page and a tall page all paint the
         ;; same retained number of cells and never see the block pinned to the
         ;; top of its slot.
         (pad (if (> budget (length cells))
                  (truncate (/ (- budget (length cells)) 2))
                0)))
    (list :lines visible
          :cells (append (make-list pad (list :text "")) cells)
          :current (and lines (car (nth index lines)))
          :position (and index (1+ index))
          :total (and lines (length lines))
          :trans (delq nil (mapcar (lambda (line)
                                    (cl-assoc (car line) trans :test #'=)) visible))
          :loading (plist-get lyric :loading))))

(defun etaf-ncm--queue-panel (model)
  "Return MODEL's queue entries.
Every entry is published, up to the canvas limit: the panel is one scrolling
canvas, the way the library list is, so a gesture runs through the whole queue
in one continuous movement."
  (let* ((queue (etaf-ncm--read model :queue))
         (songs (etaf-ncm--list (plist-get queue :songs)))
         (size (max 1 (min (length songs) etaf-ncm-render-limit)))
         (pos (or (plist-get queue :pos) 0))
         (start 0))
    (list :count (or (plist-get queue :count) 0)
          :pos pos
          :entries (cl-loop for song in (seq-take songs size)
                            for index from start
                            collect (list :index (1+ index)
                                          :name (or (plist-get song :name) "")
                                          :right (etaf-ncm--format-duration
                                                  (plist-get song :ms))
                                          :current (= (1+ index) pos))))))

(defun etaf-ncm--search-text (model text)
  "Search TEXT in MODEL, reporting an empty keyword in the player line."
  (etaf-ncm--write model :query (or text ""))
  (if (string-empty-p (string-trim (or text "")))
      (etaf-ncm--write model :message "输入关键词后开始搜索")
    (condition-case error
        (etaf-ncm-search model text)
      (etaf-ncm-error (etaf-ncm--write model :message (error-message-string error))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

(defun etaf-ncm--next-item ()
  "Move the library selection down."
  (interactive)
  (etaf-ncm-move-selection (etaf-ncm--current-model) 1))

(defun etaf-ncm--previous-item ()
  "Move the library selection up."
  (interactive)
  (etaf-ncm-move-selection (etaf-ncm--current-model) -1))

(defun etaf-ncm--queue-hit-p (xy columns rows layout pane aside)
  "Return non-nil when text-cell position XY hits the visible queue panel.
COLUMNS and ROWS describe the event window; LAYOUT, PANE and ASIDE describe
the player.  This geometry is independent of point and the selected window."
  (and (eq aside 'queue)
       (or (eq layout 'wide) (eq pane 'aside))
       (consp xy) (numberp (car xy)) (numberp (cdr xy))
       (<= (pcase layout
             ('wide (max 0 (- columns etaf-ncm-layout-aside-columns)))
             ('medium etaf-ncm-layout-rail-columns)
             (_ 0))
           (car xy))
       (< (car xy) columns)
       (<= 0 (cdr xy))
       (< (cdr xy) (etaf-ncm-layout-aside-rows layout rows))))

(defun etaf-ncm--wheel (event delta)
  "Scroll the pane under EVENT by DELTA rows.
Both panes are scrolling canvases, so a gesture goes through the same ETAF
scroll the renderer uses and stays continuous instead of turning each tick into
a page move."
  (let* ((position (event-start event))
         (window (posn-window position)))
    (when (window-live-p window)
      (with-current-buffer (window-buffer window)
        (let* ((model (etaf-ncm--current-model))
               (pixels (posn-x-y position))
               (xy (and (consp pixels)
                        (cons (/ (float (car pixels)) (window-font-width window))
                              (/ (float (cdr pixels)) (window-font-height window)))))
               (queue-p (and (null (posn-area position))
                             (etaf-ncm--queue-hit-p
                              xy (window-body-width window) (window-body-height window)
                              (etaf-ncm--read model :layout) (etaf-ncm--read model :pane)
                              (etaf-ncm--read model :aside)))))
          (cond
           (queue-p
            ;; One canvas, so a gesture moves it continuously with its
            ;; momentum, exactly as the library list does.  Moving a window of
            ;; rows a step at a time is what felt stiff.
            (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                        ((etaf-runtime-mounted-p runtime)))
              (ignore-errors
                (etaf-scroll-by runtime 'ncm-queue-scroll delta))))
           ((etaf-ncm--list-shown-p model)
            (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                        ((etaf-runtime-mounted-p runtime)))
              (ignore-errors
                (etaf-scroll-by runtime 'ncm-list-scroll delta))))))))))

(defun etaf-ncm--first-item ()
  "Select the first row of the library."
  (interactive)
  (etaf-ncm-move-selection (etaf-ncm--current-model)
                           (- (plist-get (etaf-ncm-state (etaf-ncm--current-model)) :selection))))

(defun etaf-ncm--last-item ()
  "Select the last row of the library."
  (interactive)
  (let* ((app (etaf-ncm--current-model))
         (state (etaf-ncm-state app)))
    (etaf-ncm-move-selection app (- (1- (or (plist-get state :rows-total) 1))
                                    (plist-get state :selection)))))

(defun etaf-ncm--next-page ()
  "Select one page further down the library."
  (interactive)
  (let* ((app (etaf-ncm--current-model))
         (state (etaf-ncm-state app)))
    (etaf-ncm-move-selection app (or (plist-get state :page-size) 10))))

(defun etaf-ncm--previous-page ()
  "Select one page further up the library."
  (interactive)
  (let* ((app (etaf-ncm--current-model))
         (state (etaf-ncm-state app)))
    (etaf-ncm-move-selection app (- (or (plist-get state :page-size) 10)))))

(defun etaf-ncm--activate ()
  "Play or open the selected library row."
  (interactive)
  (etaf-ncm-activate-selection (etaf-ncm--current-model)))

(defun etaf-ncm--toggle-playback ()
  "Pause or resume the current song."
  (interactive)
  (etaf-ncm-toggle-playback (etaf-ncm--current-model)))

(defun etaf-ncm--next-track ()
  "Play the next track in the queue."
  (interactive)
  (etaf-ncm-next-track (etaf-ncm--current-model)))

(defun etaf-ncm--previous-track ()
  "Play the previous track in the queue."
  (interactive)
  (etaf-ncm-previous-track (etaf-ncm--current-model)))

(defun etaf-ncm--add-to-queue ()
  "Append the selected song to the queue."
  (interactive)
  (let ((model (etaf-ncm--current-model)))
    (condition-case error
        (etaf-ncm-add-to-queue model (etaf-ncm--selected-row model))
      (etaf-ncm-error (etaf-ncm--write model :message (error-message-string error))))))

(defun etaf-ncm--download ()
  "Download the selected library row into the local library."
  (interactive)
  (etaf-ncm-download-selection (etaf-ncm--current-model)))

(defun etaf-ncm-open-cover ()
  "Open the current track's album art in the system image viewer.
A terminal cannot show the original pixels inside the buffer, so this opens
the cached artwork at full size."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (file (etaf-ncm--read model :cover-file)))
    (unless (and (stringp file) (file-readable-p file))
      (user-error "当前歌曲没有可读取的封面"))
    (call-process (if (eq system-type 'darwin) "open" "xdg-open") nil 0 nil file)))

(defun etaf-ncm--search ()
  "Ask for a keyword and search it."
  (interactive)
  (etaf-ncm--search-text (etaf-ncm--current-model)
                         (read-string "搜索歌曲、歌手、歌单或专辑：")))

(defun etaf-ncm-login (&optional app)
  "Sign in to the backend with a phone number and an SMS verification code.
APP defaults to the mounted player or the one in the current buffer.  The
phone number is read in the minibuffer, with the number the backend remembers
as the default; once the backend reports the code went out, the minibuffer
asks for it.  On success the backend stores the cookie and the player reloads
its account and libraries."
  (interactive)
  (let* ((app (or app
                  etaf-ncm--model
                  (etaf-app-state etaf-ncm-buffer-name)
                  (user-error "没有打开的网易云音乐播放器")))
         (stored (etaf-ncm--stored-phone (etaf-ncm--client app)))
         (phone (string-trim
                 (read-string (if stored
                                  (format "手机号（回车用上次 %s）：" stored)
                                "手机号：")
                              nil nil stored))))
    (when (string-empty-p phone)
      (user-error "需要手机号"))
    (etaf-ncm--login-send
     app phone
     (lambda (result)
       (when (eq (car result) :ok)
         (condition-case nil
             (let ((code (string-trim (read-string "短信验证码（收到后输入）："))))
               (if (string-empty-p code)
                   (etaf-ncm--note app "没有输入验证码，登录未完成；再按 L 重来")
                 (etaf-ncm--login-finish app phone code nil)))
           (quit (etaf-ncm--note app "登录已取消（验证码没输入）"))))))))

(defun etaf-ncm--refresh ()
  "Reload the library, playback status, queue and account."
  (interactive)
  (etaf-ncm-refresh (etaf-ncm--current-model)))

(defun etaf-ncm--sync-now-art (app cover columns rows panel metrics mode)
  "Publish APP's page backdrop and spectrum colour for COVER.
COLUMNS and ROWS size the page in cells and METRICS give the cell in pixels, so
the picture is built at the size the page will draw it.  PANEL is the colour it
fades into; a cover that cannot be turned into a picture leaves the page on the
plain cover.  The picture is built in the background and published when it
lands, so a resize never waits for ffmpeg."
  (let* ((char-width (or (plist-get metrics :char-width) (frame-char-width)))
         (line-height (or (plist-get metrics :line-height) (frame-char-height)))
         ;; The picture is sized from the same parts the page draws, so it has to
         ;; know whether the bars take rows; otherwise the bands disagree by the
         ;; height of the spectrum.
         ;; The picture is sized from the same parts the page draws, so it needs
         ;; the same two answers the page has: whether there are bars, and
         ;; whether the song has a lyric at all.
         (geometry (etaf-ncm-now-geometry columns rows char-width line-height mode
                                          (etaf-ncm--read app :spectrum)
                                          (length (etaf-ncm--read app :lyric))))
         (direction (plist-get geometry :fade))
         (window (and (plist-get app :buffer)
                      (get-buffer-window (plist-get app :buffer) t)))
         (frame (if window (window-frame window) (selected-frame)))
         (scale (max 1 (round (frame-scale-factor frame))))
         ;; A huge window is expensive to blur and the extra pixels are not
         ;; visible through the blur, so the picture stops growing there.
         (scale (if (> (* (or columns 0) char-width scale) 2400) 1 scale))
         ;; An empty rectangle means "centre the cover on the whole picture".
         ;; The poster on a small window asks for that: its text block floats
         ;; over the middle, so the artwork belongs behind it and not in a
         ;; corner, which is where a rectangle of zero cells put it.
         (area (let ((width (* (plist-get geometry :art-columns) char-width))
                     (height (* (plist-get geometry :art-rows) line-height)))
                 (and (> width 0) (> height 0)
                      (list (* (plist-get geometry :art-left) char-width)
                            (* (plist-get geometry :art-top) line-height)
                            width height))))
         (hero (and cover (> (or columns 0) 0) (> (or rows 0) 0)
                    (etaf-ncm-hero-file
                     cover
                     (* (plist-get geometry :hero-columns) char-width)
                     (* (plist-get geometry :hero-rows) line-height)
                     panel direction area scale
                     (lambda (file)
                       (when (and (eq (etaf-ncm--read app :screen) 'now)
                                  (equal (etaf-ncm--read app :cover-file) cover))
                         (etaf-ncm--write app :hero file)))))))
    ;; Publish nil while the new size renders: a picture built for another
    ;; size would be stretched into this band, which is exactly the squash a
    ;; resize must not show.  The page falls back to the panel colour for the
    ;; moment the build takes.
    ;; A render that failed, or one still running for a new size, leaves the
    ;; picture that is already there: writing nil is what turned the page black.
    (when hero (etaf-ncm--write app :hero hero))
    (etaf-ncm--write app :hero-accent (and cover (etaf-ncm-hero-accent cover)))))

(defun etaf-ncm--ensure-now-art (app)
  "Build APP's page backdrop for the page's current cell geometry.
The page frame already runs while the page is open, so the backdrop is built
here too: the effect that used to start it could run with another buffer
current and skip the build, which is why a resize only sometimes showed a
picture."
  (let* ((columns (or (etaf-ncm--read app :columns) 0))
         (rows (or (etaf-ncm--read app :window-rows) 0))
         (mode (etaf-ncm--read app :now-mode))
         (cover (etaf-ncm--read app :cover-file))
         (panel (plist-get (etaf-ncm--read app :theme) :ui-bg))
         (metrics (etaf-ncm--display-metrics (plist-get app :buffer)))
         ;; The cell is part of the key: a window that keeps its column count but
         ;; changes its pixel size (a font change, a scroll bar appearing) would
         ;; otherwise keep a picture built for the old shape.  It is a whole
         ;; number of pixels per cell, so an unchanged window keeps it stable.
         (key (list columns rows
                    (plist-get metrics :char-width)
                    (plist-get metrics :line-height)
                    mode panel cover)))
    (unless (equal key (plist-get app :now-art-key))
      (setf (plist-get app :now-art-key) key)
      (etaf-ncm--sync-now-art app cover columns rows panel metrics mode))))

(defun etaf-ncm--visual-tick (app)
  "Advance APP's page spectrum from the audio the player is decoding.
The meter follows the source mpv reports, so the bars move with the music; a
paused player, a missing ffmpeg or an ended track leaves them at silence and
the page keeps rendering."
  (when (eq (etaf-ncm--read app :screen) 'now)
    (let* ((status (etaf-ncm--read app :status))
           (source (plist-get status :source))
           ;; The track, not its URL, is the cache key: the URL carries a fresh
           ;; signed query on every request, so the same song would never hit the
           ;; copy the meter already decoded for it.
           (key (let ((title (plist-get status :title))
                      (artist (plist-get status :artist)))
                  (and (stringp title) (not (string-empty-p title))
                       (format "%s\t%s\t%s"
                               title (or artist "")
                               (or (plist-get status :album) ""))))))
      (if (etaf-ncm--playing-p app)
          (progn
            (when key (etaf-ncm-meter--ensure-cache source key))
            (etaf-ncm-meter-start source (etaf-ncm--clock app) key))
        (etaf-ncm-meter-stop))
      ;; The levels travel to the page, not a string: the page decides how many
      ;; bars fit the band it has.
      (etaf-ncm--write app :spectrum
                       (append (etaf-ncm-meter-levels etaf-ncm-now-bars) nil)))))

(defun etaf-ncm--start-visual (app)
  "Start APP's page frames: twelve spectrum samples a second."
  (unless (plist-get app :visual-timer)
    (setf (plist-get app :visual-timer)
          (run-with-timer 0 (/ 1.0 12)
                          (lambda () (etaf-ncm--visual-tick app))))))

(defun etaf-ncm--stop-visual (app)
  "Stop APP's page frames and the decoder behind them."
  (when-let* ((timer (plist-get app :visual-timer)))
    (cancel-timer timer)
    (setf (plist-get app :visual-timer) nil))
  (etaf-ncm-meter-stop))

(defun etaf-ncm--open-now ()
  "Show the full-page view of the playing song."
  (interactive)
  (etaf-ncm--write (etaf-ncm--current-model) :screen 'now))

(defun etaf-ncm--toggle-now ()
  "Open the playing page, or leave it when it is already open.
The same key does both, so a small window that hides the back control still
has a way out."
  (interactive)
  (let ((model (etaf-ncm--current-model)))
    (if (eq (etaf-ncm--read model :screen) 'now)
        (etaf-ncm--write model :screen 'library)
      (etaf-ncm--write model :screen 'now))))

(defun etaf-ncm--toggle-now-mode ()
  "Switch the full-page view between the one-picture and the split design."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (mode (etaf-ncm--read model :now-mode)))
    ;; From `auto', the first press shows the other design than the one on
    ;; screen, so one key always changes what the page looks like.
    (etaf-ncm--write model :now-mode
                     (cond ((eq mode 'split) 'immersive)
                           ((eq mode 'immersive) 'split)
                           (t (if (< (or (etaf-ncm--read model :columns) 0) 96)
                                  'split 'immersive))))))

(defun etaf-ncm--back ()
  "Leave the full-page view and return to the player.
In the player itself this does nothing, so Esc stays free for the other panes."
  (interactive)
  (let ((model (etaf-ncm--current-model)))
    (when (eq (etaf-ncm--read model :screen) 'now)
      (etaf-ncm--write model :screen 'library))))

(defun etaf-ncm--toggle-aside ()
  "Switch the side panel between the lyrics and the queue."
  (interactive)
  (etaf-ncm-toggle-aside (etaf-ncm--current-model)))

(defun etaf-ncm--toggle-pane ()
  "Show the library list or the lyrics and queue panel.
In a wide layout, which shows both, this keeps the library list focused."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (showing (eq (etaf-ncm--read model :pane) 'aside)))
    (etaf-ncm-show-pane model (if showing 'list 'aside))))

(defun etaf-ncm--toggle-repeat ()
  "Turn list repeat (列表循环) on or off."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (on (not (plist-get (etaf-ncm--view-status model) :repeat))))
    (etaf-ncm-set-repeat model on)))

(defun etaf-ncm--toggle-shuffle ()
  "Turn shuffle mode on or off."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (on (not (plist-get (etaf-ncm--view-status model) :shuffle))))
    (etaf-ncm-set-shuffle model on)))

(defun etaf-ncm--like ()
  "Add the current song to the liked songs."
  (interactive)
  (etaf-ncm-like (etaf-ncm--current-model)))

(defun etaf-ncm--unlike ()
  "Remove the current song from the liked songs."
  (interactive)
  (etaf-ncm-like (etaf-ncm--current-model) t))

(defun etaf-ncm--volume-up ()
  "Raise the volume by ten."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (volume (or (etaf-ncm--flag-value model :volume) 0)))
    (etaf-ncm-set-volume model (min 100 (+ volume 10)))))

(defun etaf-ncm--volume-down ()
  "Lower the volume by ten."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (volume (or (etaf-ncm--flag-value model :volume) 0)))
    (etaf-ncm-set-volume model (max 0 (- volume 10)))))

(defun etaf-ncm--seek-back ()
  "Seek ten seconds backwards."
  (interactive)
  (etaf-ncm-seek (etaf-ncm--current-model) -10))

(defun etaf-ncm--seek-forward ()
  "Seek ten seconds forwards."
  (interactive)
  (etaf-ncm-seek (etaf-ncm--current-model) 10))

(defun etaf-ncm--toggle-theme ()
  "Switch the player between the dark and light palette.
The mode cell is the player's one appearance state: `T' writes the same cell
`etaf-ncm--theme-mode' that a panel's title bar writes, so whichever one
switches, the player and the panel around it repaint together."
  (interactive)
  (let* ((model (etaf-ncm--current-model))
         (mode (if (eq (etaf-ncm--effective-mode) 'dark) 'light 'dark)))
    (setq etaf-ncm-theme-mode mode)
    (etaf-set-value etaf-ncm--theme-mode mode)
    (etaf-ncm--write model :theme (etaf-ncm-theme-defaults mode))
    (etaf-ncm--write model :message
                     (format "外观：%s" (if (eq mode 'dark)
                                           "深色"
                                         "浅色")))))

(defun etaf-ncm--locate-index (index)
  "Show the sidebar library at 1-based position INDEX."
  (interactive "p")
  (let ((entry (nth (1- index) (apply #'append (mapcar #'cdr etaf-ncm-sections))))
        (model (etaf-ncm--current-model)))
    (if entry
        (etaf-ncm-locate model (car entry))
      (etaf-ncm--write model :message (format "没有第 %s 个音乐库" index)))))

(defun etaf-ncm--key-command (session command)
  "Return COMMAND as a key command acting on SESSION.
Binding the session lets an embedded player share the buffer-free commands."
  (lambda ()
    (interactive)
    (let ((etaf-ncm--model session))
      (call-interactively command))))

(defun etaf-ncm--keys (session)
  "Return the player-wide `:keys' of SESSION's root.
Arrows, RET and Tab stay with the focused region, so a focus group, a range
or the library list keeps them; `?' opens the read-only ETAF key help."
  (append
   (mapcar
    (lambda (entry)
      (list (car entry) (etaf-ncm--key-command session (nth 1 entry)) (nth 2 entry)))
    '(("SPC" etaf-ncm--toggle-playback "播放 / 暂停")
      ("n" etaf-ncm--next-track "下一首")
      ("p" etaf-ncm--previous-track "上一首")
      ("a" etaf-ncm--add-to-queue "选中歌曲加入队列")
      ("d" etaf-ncm--download "下载选中歌曲")
      ("s" etaf-ncm--search "搜索")
      ("/" etaf-ncm--search "搜索")
      ("g" etaf-ncm--refresh "刷新")
      ("i" etaf-ncm--toggle-aside "切换歌词 / 队列")
      ("o" etaf-ncm--toggle-now "播放页：进入 / 返回")
      ("v" etaf-ncm--toggle-pane "切换列表 / 面板")
      ("m" etaf-ncm--toggle-now-mode "播放页：沉浸 / 分栏")
      ("r" etaf-ncm--toggle-repeat "列表循环")
      ("z" etaf-ncm--toggle-shuffle "随机播放")
      ("c" etaf-ncm-open-cover "在系统查看器打开封面")
      ("f" etaf-ncm--like "喜欢")
      ("F" etaf-ncm--unlike "取消喜欢")
      ("+" etaf-ncm--volume-up "音量 +10")
      ("=" etaf-ncm--volume-up "音量 +10")
      ("-" etaf-ncm--volume-down "音量 -10")
      ("," etaf-ncm--seek-back "快退 10 秒")
      ("." etaf-ncm--seek-forward "快进 10 秒")
      ("L" etaf-ncm-login "短信登录")
      ("T" etaf-ncm--toggle-theme "切换深浅色")
      ("q" etaf-ncm-close "关闭窗口（音乐继续）")
      ("Q" etaf-ncm-quit "退出客户端（停止音乐）")))
   ;; The wheel scrolls the pane under the pointer: the queue moves its
   ;; window, the library moves its scrolling canvas.
   (mapcar (lambda (entry)
             (let ((direction (cdr entry)))
               (list (car entry)
                     (lambda (event)
                       (interactive "e")
                       (let ((etaf-ncm--model session))
                         (etaf-ncm--wheel event
                                          (* direction etaf-ncm-wheel-rows)))))))
           '(("<wheel-up>" . -1) ("<wheel-down>" . 1)))
   (cl-loop for entry in (apply #'append (mapcar #'cdr etaf-ncm-sections))
            for index from 1 to 9
            collect (let ((index index))
                      (list (number-to-string index)
                            (lambda ()
                              (interactive)
                              (let ((etaf-ncm--model session))
                                (etaf-ncm--locate-index index)))
                            (format "音乐库：%s" (nth 1 entry)))))))

(defun etaf-ncm--list-keys (session)
  "Return the library list's `:keys' for SESSION.
The list is one focus stop whose directions move the selection through its
`:on-direction' handler, not the focus."
  (mapcar
   (lambda (entry)
     (list (car entry) (etaf-ncm--key-command session (nth 1 entry)) (nth 2 entry)))
   '(("C-n" etaf-ncm--next-item nil)
     ("C-p" etaf-ncm--previous-item nil)
     ("<home>" etaf-ncm--first-item "第一行")
     ("<end>" etaf-ncm--last-item "最后一行")
     ("<next>" etaf-ncm--next-page "下一页")
     ("<prior>" etaf-ncm--previous-page "上一页")
     ("RET" etaf-ncm--activate "播放选中行"))))

(defun etaf-ncm--queue-step (session delta)
  "Move queue focus by DELTA cells in SESSION, scrolling past the pool edge."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (ref (etaf-focused-host-ref runtime))
         (name (and (symbolp ref) (symbol-name ref)))
         (index (and name (string-prefix-p "ncm-queue-cell-" name)
                     (string-to-number (substring name 15))))
         (visible (length (plist-get (etaf-ncm--queue-panel session) :entries)))
         (target (and index (+ index delta))))
    (cond ((null index) (etaf-focus-within runtime 'ncm-queue))
          ((and (>= target 0) (< target visible))
           (etaf-focus runtime (intern (format "ncm-queue-cell-%d" target))))
          (t (etaf-ncm--scroll-queue session delta)))))

(defun etaf-ncm--queue-keys (session)
  "Return the queue group's `:keys' for SESSION.
The queue is one focus group whose directions move the selection through its
`:on-direction' handler."
  (let ((page (lambda (sign)
                (lambda ()
                  (interactive)
                  (etaf-ncm--scroll-queue
                   session (* sign (max 1 (etaf-ncm--read session :queue-rows))))))))
    (list (list "C-n" (lambda () (interactive) (etaf-ncm--queue-step session 1)))
          (list "C-p" (lambda () (interactive) (etaf-ncm--queue-step session -1)))
          (list "<next>" (funcall page 1) "队列下一页")
          (list "<prior>" (funcall page -1) "队列上一页"))))

(defun etaf-ncm--reveal-selection (session)
  "Put point on SESSION's selection bar and scroll its canvas to it.
The list is one focus stop, so the cursor follows the selection bar; the
scrolling canvas follows the bar so arrow keys never select an off-screen row."
  (when-let* ((buffer (plist-get session :buffer))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer))
              ((etaf-runtime-mounted-p runtime))
              (bounds (etaf-host-ref-bounds runtime 'ncm-list-selection)))
    (when (eq (etaf-focused-host-ref runtime) 'ncm-list)
      (with-current-buffer buffer
        (goto-char (car bounds))
        (dolist (window (get-buffer-window-list buffer nil t))
          (set-window-point window (car bounds)))))
    (ignore-errors
      (etaf-scroll-into-view runtime (intern (format "ncm-row-%d"
                                                     (etaf-ncm--read session :selection)))))))

(defun etaf-ncm--settle-focus (session)
  "Keep keyboard focus inside a visible region of SESSION.
Hiding a pane clears the focus inside it; the shown pane then receives it:
inside a card the library list or the card's pane switch, otherwise the
library list, else the queue at its playing entry, else the lyric tabs."
  (when-let* ((buffer (plist-get session :buffer))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer)))
    (with-current-buffer buffer
      (unless (etaf-focused-host-ref runtime)
        (ignore-errors
          (cond ((etaf-ncm-layout-widget-p (etaf-ncm--read session :layout))
                 (cond ((etaf-ncm--list-shown-p session)
                        (etaf-focus runtime 'ncm-list))
                       ;; A tile has no switch row; its play control is the
                       ;; nearest stop, and it keeps point off the buffer end
                       ;; where a stray cursor would paint under the transport.
                       ((ignore-errors (etaf-focus-within runtime 'ncm-card-tabs) t))
                       (t (ignore-errors (etaf-focus runtime 'ncm-play) t))))
                ((and (etaf-ncm--aside-shown-p session)
                      (or (eq (etaf-ncm--read session :pane) 'aside)
                          (not (etaf-ncm--list-shown-p session))))
                 (etaf-focus-within runtime (if (eq (etaf-ncm--read session :aside) 'queue)
                                                'ncm-aside-queue
                                              'ncm-aside-lyrics)))
                ((etaf-ncm--list-shown-p session) (etaf-focus runtime 'ncm-list))))))))

;;; ---------------------------------------------------------------------------
;;; Application Component and entry points
;;; ---------------------------------------------------------------------------

(etaf-define-component etaf-ncm-app (&key model)
  "Render the player for MODEL and own its session lifecycle.
MODEL must come from `etaf-ncm-create'.  Mounting provides the palette for the
subtree, starts playback polling and loads the current library; unmounting
releases the polling timer and the session's pending backend requests."
  :bindings ((session (or model
                          (signal 'etaf-ncm-error
                                  '("etaf-ncm-app needs the :model from `etaf-ncm-create'"))))
             (palette (etaf-ncm--ref session :theme))
             (cover-file (etaf-ncm--ref session :cover-file))
             (track-title (etaf-ncm--status-source session :title))
             (track-artist (etaf-ncm--status-source session :artist))
             (track-vip (etaf-ncm--status-source session :vip))
             (track-quality (etaf-ncm--status-source session :quality))
             (track-duration (etaf-ncm--status-source session :duration))
             (queue-count (etaf-ncm--status-source session :queue-count))
             (position (etaf-ncm--ref session :position-ref))
             (lyric-panel (etaf-computed (lambda () (etaf-ncm--lyric-panel session)) :test #'equal))
             (queue-panel (etaf-computed (lambda () (etaf-ncm--queue-panel session)) :test #'equal))
             ;; The transport glyph reads the retained state source directly;
             ;; the view never reads the state itself, so a toggle publishes a
             ;; prepared text update instead of re-rendering the app.
             (playing (etaf-computed
                       (lambda ()
                         (eq (etaf-value (etaf-ncm--ref session :state-ref)) 'playing))))
             ;; Callbacks are instance values, not per-render closures: a
             ;; re-render that passes a new function object to a keyed child
             ;; would make that child render again for nothing.
             (on-locate (lambda (section) (etaf-ncm-locate session section)))
             (on-search (lambda (text) (etaf-ncm--search-text session text)))
             (on-play-library (lambda () (etaf-ncm-play session)))
             (on-refresh (lambda () (etaf-ncm-refresh session)))
             (on-press-row (lambda (index) (etaf-ncm-press-row session index)))
             (on-row-action (lambda (index key)
                              (etaf-ncm-row-action session index key)))
             (on-switch-aside (lambda (panel)
                                (etaf-ncm--write session :aside panel)
                                ;; The tab row belongs to the aside variant
                                ;; that just hid; continue on the shown one.
                                (etaf-next-tick
                                 (lambda ()
                                   (when-let* ((runtime (etaf-runtime-for-buffer
                                                         (plist-get session :buffer))))
                                     (ignore-errors
                                       (etaf-focus-within
                                        runtime (intern (format "ncm-aside-%s" panel)))))))))
             (keys (etaf-ncm--keys session))
             (list-keys (etaf-ncm--list-keys session))
             (queue-keys (etaf-ncm--queue-keys session))
             (list-direction
              (lambda (direction)
                (let ((etaf-ncm--model session))
                  (pcase direction
                    ('down (etaf-ncm--next-item) 'handled)
                    ('up (etaf-ncm--previous-item) 'handled)
                    (_ 'release)))))
             (queue-direction
              (lambda (direction)
                (pcase direction
                  ('down (etaf-ncm--queue-step session 1) 'handled)
                  ('up (etaf-ncm--queue-step session -1) 'handled)
                  (_ 'release))))
             (on-list-focus (lambda () (etaf-ncm--reveal-selection session)))
             (on-jump-queue (lambda (index) (etaf-ncm-jump-queue session index)))
             (on-show-pane (lambda (target) (etaf-ncm-show-pane session target)))
             ;; A card names two libraries instead of a generic list tab, so a
             ;; press both loads that library and brings the list into front.
             (on-open-library (lambda (section)
                                (etaf-ncm-locate session section)
                                (etaf-ncm-show-pane session 'list)))
             (on-show-aside (lambda (target)
                              (etaf-ncm--write session :aside target)
                              (etaf-ncm-show-pane session 'aside)))
             (on-toggle (lambda () (etaf-ncm-toggle-playback session)))
             (on-next (lambda () (etaf-ncm-next-track session)))
             (on-previous (lambda () (etaf-ncm-previous-track session)))
             (on-stop (lambda () (etaf-ncm-stop session)))
             (on-like (lambda ()
                        ;; The heart is a toggle: a press on a liked song
                        ;; removes the like.  The retained like source, not the
                        ;; last repainted status, is the current reading.
                        (etaf-ncm-like session
                                       (and (etaf-ncm--flag-value session :liked) t))))
             (on-add (lambda ()
                       (when-let* ((row (etaf-ncm--selected-row session)))
                         (etaf-ncm-add-to-queue session row))))
             (on-lyrics (lambda ()
                          (etaf-batch
                            (etaf-ncm--write session :aside 'lyrics)
                            (etaf-ncm-show-pane session 'aside))))
             (on-queue (lambda ()
                         (etaf-batch
                           (etaf-ncm--write session :aside 'queue)
                           (etaf-ncm-show-pane session 'aside))))             (on-volume (lambda (percent) (etaf-ncm-set-volume session percent)))
             (on-seek (lambda (seconds) (etaf-ncm-seek-to session seconds)))
             (on-shuffle (lambda ()
                           (etaf-ncm-set-shuffle
                            session
                            (not (etaf-ncm--flag-value session :shuffle)))))
             (on-repeat (lambda ()
                          (etaf-ncm-set-repeat
                           session
                           (not (etaf-ncm--flag-value session :repeat)))))
             ;; Aside and pane sources are read inside Host bindings, so a panel
             ;; switch publishes retained visibility and paint instead of
             ;; re-rendering the app.
             (lyrics-visible (etaf-computed
                              (lambda ()
                                (and (eq (etaf-value (etaf-ncm--ref session :aside)) 'lyrics)
                                     (etaf-ncm--aside-shown-p session)))))
             (queue-visible (etaf-computed
                             (lambda ()
                               (and (eq (etaf-value (etaf-ncm--ref session :aside)) 'queue)
                                    (etaf-ncm--aside-shown-p session)))))
             (pane-list (etaf-computed
                         (lambda ()
                           (eq (etaf-value (etaf-ncm--ref session :pane)) 'list))))
             (list-visible (etaf-computed
                            (lambda () (etaf-ncm--list-shown-p session))))
             ;; The lyric panel's album line follows the selection through a
             ;; retained source the model writes, so a row move repaints only
             ;; that text instead of re-rendering the aside.
             (selected-album (etaf-ncm--ref session :selected-album))
             ;; The full-page view: a press on the playing cover opens it and
             ;; its own controls close it.  The page reads the same retained
             ;; sources as the bar, so playback keeps painting behind it.
             (screen (etaf-ncm--ref session :screen))
             (hero (etaf-ncm--ref session :hero))
             (hero-accent (etaf-ncm--ref session :hero-accent))
             (now-visible (etaf-computed
                           (lambda ()
                             (eq (etaf-value (etaf-ncm--ref session :screen)) 'now))))
             ;; The page sizes itself from the region it covers: the same
             ;; geometry drives the picture builder and the layout.
             (now-geometry
              (etaf-computed
               (lambda ()
                 (let ((metrics (etaf-display-metrics)))
                   (etaf-ncm-now-geometry
                    (or (etaf-value (etaf-ncm--ref session :columns)) 0)
                    (or (etaf-value (etaf-ncm--ref session :window-rows)) 0)
                    (plist-get metrics :char-width)
                    (plist-get metrics :line-height)
                    (etaf-value (etaf-ncm--ref session :now-mode))
                    (etaf-value (etaf-ncm--ref session :spectrum))
                    (length (etaf-value (etaf-ncm--ref session :lyric))))))
               :test #'equal))
             ;; The geometry already decided which parts fit, so the page draws
             ;; that list instead of asking again with a different row count.
             (now-sections (etaf-computed
                            (lambda () (plist-get (etaf-value now-geometry) :sections))
                            :test #'equal))
             ;; The page asks for a lyric window as tall as its own slot, so
             ;; the block is centred in the panel instead of clipped at the top.
             (now-lyric (etaf-computed
                         (lambda ()
                           (etaf-ncm--lyric-panel
                            session
                            (plist-get (etaf-value now-sections) :lyrics)))
                         :test #'equal))
             (on-cover (lambda () (etaf-ncm--write session :screen 'now)))
             (on-back (lambda () (etaf-ncm--write session :screen 'library)))
             (on-login (lambda ()
                         (unless (etaf-ncm--read session :account)
                           (etaf-ncm-login session)))))
  :setup
  (progn
    ;; Every page that reads the session's buffer — the page backdrop, the
    ;; focus hand-off, the highlight geometry — needs to know which buffer the
    ;; session is drawn in.  Only `etaf-ncm-open' used to record it, so a player
    ;; embedded in a posframe panel had none, and the first read asked
    ;; `get-buffer' about nil: `Wrong type argument: stringp, nil' the moment
    ;; the page opened.  `:setup' runs inside the mount, so this is that buffer.
    (setf (plist-get session :buffer) (current-buffer))
    (etaf-theme-provide palette)
    ;; One appearance state: the palette follows the player's mode cell and
    ;; the appearance its host provides, and the host paints from the same
    ;; cell, so `T' and a panel's title-bar switch repaint both.
    (etaf-watch (lambda () (etaf-ncm-theme-defaults))
                (lambda (theme _old) (etaf-ncm--write session :theme theme))
                :immediate t :test #'equal :name 'etaf-ncm-theme)
    (when-let* ((surface (etaf-surface-host)))
      (etaf-surface-declare surface :theme palette
                            :mode etaf-ncm--theme-mode
                            :modes etaf-ncm--theme-modes))
    ;; The mounted player lays out for the region it is given: its own
    ;; buffer window when it stands alone, or the host window, pane or tab
    ;; that embeds it (see `etaf-viewport').
    ;; A watcher, not an effect: the sync reads the values it writes, and
    ;; an effect would rerun on its own writes and undo a pane chosen in a
    ;; wide layout.
    ;; `etaf-viewport' is the region the Runtime is mounted in, and inside a
    ;; posframe that is the posframe's own box.  Trust it: reading the window
    ;; instead picked up whichever window happened to show the buffer (the main
    ;; frame, a pop-up, the one behind the posframe) and laid the page out for
    ;; that, so the artwork was built for a size it was never drawn at — one
    ;; picture in a corner, a block of panel colour beside it.
    (etaf-watch #'etaf-viewport
                (lambda (viewport _old)
                  (when viewport
                    (etaf-ncm--sync-viewport session viewport))
                  nil)
                :immediate t)
    ;; The page's backdrop is a file, not a live picture: build it when the
    ;; page opens, when the playing song changes and when the window resizes.
    ;; The Builder reads only its inputs, so the refs it publishes cannot wake
    ;; it again; a cover that cannot be turned into a picture leaves the page
    ;; on the plain cover.
    ;; Escape is framework-owned: it dismisses the innermost Host with an
    ;; `:on-dismiss' handler, so the page must own the focus when it opens; the
    ;; same switch starts and stops the frames and the decoder behind them.
    ;; The backdrop follows the page's own inputs: opening it, resizing the
    ;; window, changing the design or the playing cover rebuilds it once.
    ;; Nothing on the frame clock touches it.
    (etaf-watch (lambda ()
                  (list (etaf-value (etaf-ncm--ref session :screen))
                        (etaf-value (etaf-ncm--ref session :columns))
                        (etaf-value (etaf-ncm--ref session :window-rows))
                        (etaf-value (etaf-ncm--ref session :now-mode))
                        (etaf-value (etaf-ncm--ref session :cover-file))))
                (lambda (_value _old)
                  (when (eq (etaf-ncm--read session :screen) 'now)
                    (ignore-errors (etaf-ncm--ensure-now-art session)))
                  nil))
    (etaf-watch (lambda () (etaf-value (etaf-ncm--ref session :screen)))
                (lambda (value _old)
                  (if (eq value 'now)
                      (progn
                        (etaf-ncm--start-visual session)
                        (etaf-next-tick
                         (lambda ()
                           (when-let* ((runtime (etaf-runtime-for-buffer
                                                 (plist-get session :buffer))))
                             (ignore-errors
                               (etaf-focus-within runtime 'ncm-now-back))))))
                    (etaf-ncm--stop-visual session))
                  nil)
                :name 'ncm-screen-focus)
    (etaf-watch-effect
     (lambda ()
       (when (eq (etaf-value (etaf-ncm--ref session :screen)) 'now)
         (let ((cover (etaf-value (etaf-ncm--ref session :cover-file)))
               (columns (etaf-value (etaf-ncm--ref session :columns)))
               (rows (etaf-value (etaf-ncm--ref session :window-rows)))
               (panel (plist-get (etaf-value (etaf-ncm--ref session :theme)) :ui-bg))
               (mode (etaf-value (etaf-ncm--ref session :now-mode)))
               ;; One place decides the cell, so a build started from here and
               ;; one started from a resize cannot disagree about the picture.
               (metrics (etaf-ncm--display-metrics (plist-get session :buffer))))
           (etaf-next-tick
            (lambda ()
              (etaf-ncm--sync-now-art session cover columns rows panel metrics
                                      mode)))))
       nil)
     :name 'ncm-now-art)
    ;; The two overlay bars follow line targets through `etaf-transition':
    ;; a selection or playback move slides each bar on the shared clock, so
    ;; only the damaged rows repaint.  The Scope owns both runs and stops
    ;; them on unmount.
    (let* ((lines (etaf-ncm--list-highlights session))
           (selection-target (etaf-ref (car lines) :name 'ncm-selection-target))
           (playing-target (etaf-ref (cdr lines) :name 'ncm-playing-target))
           (selection-bar (etaf-transition selection-target
                                           :duration 0.15 :easing 'ease-out
                                           :name 'ncm-selection-bar))
           (playing-bar (etaf-transition playing-target
                                         :duration 0.15 :easing 'ease-out
                                         :name 'ncm-playing-bar)))
      (setf (plist-get session :highlight-targets)
            (cons selection-target playing-target))
      (etaf-watch selection-bar
                  (lambda (line _old)
                    (etaf-ncm--apply-highlight-geometry
                     session 'ncm-list-selection line)
                    (etaf-next-tick (lambda () (etaf-ncm--reveal-selection session))))
                  :name 'ncm-selection-bar-move)
      (etaf-watch playing-bar
                  (lambda (line _old)
                    (etaf-ncm--apply-highlight-geometry
                     session 'ncm-list-playing line))
                  :name 'ncm-playing-bar-move))
    (etaf-watch-effect
     (lambda ()
       (etaf-ncm--schedule-list-highlights session
                                           (etaf-ncm--list-highlights session))))
    (etaf-watch (lambda () (list (etaf-value pane-list) (etaf-value list-visible)
                                 (etaf-value lyrics-visible) (etaf-value queue-visible)))
                (lambda (&rest _)
                  (etaf-next-tick (lambda () (etaf-ncm--settle-focus session))))
                :flush 'post :test #'equal)
    (etaf-on-mounted
     (lambda ()
       (etaf-ncm--start session)
       (etaf-ncm-refresh session)
       (etaf-next-tick (lambda () (etaf-ncm--settle-focus session)))))
    (etaf-on-unmounted
     (lambda ()
       (etaf-ncm--stop-visual session)
       (etaf-ncm--dispose session))))
  :view
  (flex :position 'relative :flex-direction 'column :width 'stretch :height 'stretch
        ;; The shell paints no margin of its own: one clear line at the top is
        ;; the panels' own top padding and one under the player belongs to the
        ;; player bar, so the surface stays one background at every size.
        ;; The root's own colour is what Ebox paints the window's partial last
        ;; row with (`ebox--sync-canvas'), and that strip sits under the
        ;; transport.  Every region above it paints its own background, so only
        ;; the strip shows this colour, and it is the bar's surface.
        :color (etaf-ncm-color :ink) :bgcolor (etaf-ncm-color :panel)
        :keys keys :aria-label "网易云音乐"
        :help '("音乐由独立的 mpv 后端播放；查看帮助不会暂停播放或改变队列。"
                "关闭窗口后音乐继续，退出客户端才会停止播放。登录过期时可重新登录并刷新曲库。")
    (etaf-ncm--view-card
     :if (etaf-ncm-layout-widget-p (etaf-ncm--read session :layout))
     :model session
     :tile (eq (etaf-ncm--read session :layout) 'tile)
     :title track-title :artist track-artist :album selected-album :cover cover-file
     :liked (etaf-ncm--ref session :liked-ref)
     :projection lyric-panel :rows (etaf-ncm--read session :lyric-rows)
     :queue-projection queue-panel
     :pane-list pane-list :lyrics lyrics-visible :queue queue-visible
     :playing playing :elapsed position :duration track-duration
     :selection (etaf-ncm--ref session :selection)
     :list-keys list-keys :list-direction list-direction :on-list-focus on-list-focus
     :on-press on-press-row :on-action on-row-action
     :queue-keys queue-keys :queue-direction queue-direction :on-jump on-jump-queue
     :on-toggle on-toggle :on-next on-next :on-previous on-previous
     :on-like on-like :on-seek on-seek
     :section (etaf-ncm--ref session :section)
     :on-library on-open-library :on-aside on-show-aside :on-cover on-cover
     :error (etaf-ncm--read session :error)
     :message (etaf-ncm--ref session :message))
    (box :width 'stretch :flex-grow 1 :flex-basis '(lh 0) :min-height '(lh 0))
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'wide)
       :model session
       :height (if-let* ((rows (etaf-ncm--read session :window-rows)))
                   (list 'lh (etaf-ncm-layout-aside-rows
                              (etaf-ncm--read session :layout) rows))
                 '(% 100))
       :groups etaf-ncm-sections
       :on-locate on-locate
       :on-login on-login)
      (etaf-ncm--view-sidebar
       :if (eq (etaf-ncm--read session :layout) 'medium)
       :compact t
       :model session
       :height (if-let* ((rows (etaf-ncm--read session :window-rows)))
                   (list 'lh (etaf-ncm-layout-aside-rows
                              (etaf-ncm--read session :layout) rows))
                 '(% 100))
       :groups etaf-ncm-sections
       :on-locate on-locate
       :on-login on-login)
      (etaf-ncm--view-list-panel
       :if (not (etaf-ncm-layout-widget-p (etaf-ncm--read session :layout)))
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :visible list-visible
        (etaf-ncm--view-header
         :model session
         :layout (etaf-ncm--read session :layout)
         :columns (etaf-ncm--read session :columns)
         :short (etaf-ncm-layout-short-p (etaf-ncm--read session :window-rows))
         :on-search on-search
         :on-play-library on-play-library
         :on-refresh on-refresh)
        (etaf-ncm--view-chips
         :if (eq (etaf-ncm--read session :layout) 'narrow)
         :model session
         :columns (etaf-ncm--read session :columns)
         :groups etaf-ncm-sections
         :on-locate on-locate)
        (flex :position 'absolute :z-index 0
              ;; The banner starts where the page starts: under the header in
              ;; every tier, and under the chip strip in the narrow one.
              :left (list 'ch (if (etaf-ncm--compact-layout-p session) 1 2))
              :top (list 'lh (1- (etaf-ncm-layout-list-top
                                  (etaf-ncm--read session :layout))))
              :visibility (if (etaf-ncm--read session :error) 'visible 'hidden)
              :width (list 'ch (etaf-ncm-layout-list-columns
                                (etaf-ncm--read session :layout)
                                (etaf-ncm--read session :columns)))
              ;; Long failures used to be clipped to one third of the bar; the
              ;; banner wraps them across the library width instead.
              :height (list 'lh (etaf-ncm--notice-lines
                                (etaf-ncm--read session :message)
                                (etaf-ncm--read session :layout)
                                (etaf-ncm--read session :columns)))
              :align-items 'start :padding '((lh 0) (ch 1))
              :background-color (etaf-ncm-color :danger-bg)
              :color (etaf-ncm-color :danger)
          (box :height 'stretch :overflow 'hidden :wrap-mode 'word
            (text (expr (or (etaf-ncm--reactive-text (etaf-ncm--ref session :message)) "")))))
        (etaf-ncm--view-list
         :model session
         :compact (etaf-ncm--compact-layout-p session)
         :selection (etaf-ncm--ref session :selection)
         :keys list-keys :on-direction list-direction :on-focus on-list-focus
         :on-press on-press-row
         :on-action on-row-action))
      (etaf-ncm--view-aside
       :if (not (etaf-ncm-layout-widget-p (etaf-ncm--read session :layout)))
       :kind 'lyrics :visible lyrics-visible
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :title track-title :artist track-artist :album selected-album :cover cover-file
       :projection lyric-panel :rows (etaf-ncm--read session :lyric-rows)
       :on-switch on-switch-aside)
      (etaf-ncm--view-aside
       :if (not (etaf-ncm-layout-widget-p (etaf-ncm--read session :layout)))
       :kind 'queue :visible queue-visible
       :layout (etaf-ncm--read session :layout)
       :columns (etaf-ncm--read session :columns)
       :window-rows (etaf-ncm--read session :window-rows)
       :projection queue-panel :rows (etaf-ncm--read session :queue-rows)
       :queue-keys queue-keys
       :queue-direction queue-direction
       :on-switch on-switch-aside
       :on-jump on-jump-queue)
    (etaf-ncm--view-pane-tabs
     :if (and (etaf-ncm--compact-layout-p session)
              (not (etaf-ncm-layout-widget-p (etaf-ncm--read session :layout))))
     :pane-list pane-list
     :lyrics lyrics-visible
     :queue queue-visible
     :on-pane on-show-pane
     :on-aside on-show-aside)
    ;; The bar reserves five lines; the positioned host in flow and the
    ;; absolute panel inside is the retained publication address, so a control
    ;; toggle updates its Hosts without a view rebuild.
    (box :if (not (etaf-ncm-layout-widget-p (etaf-ncm--read session :layout)))
         :position 'relative :z-index 0 :width 'stretch
         :height (list 'lh etaf-ncm-layout-bar-rows)
         :flex-shrink 0
      (etaf-ncm--view-player
       :compact (etaf-ncm--compact-layout-p session)
       :title track-title :artist track-artist :vip track-vip :quality track-quality
       :cover cover-file
       :playing playing
       :elapsed position :duration track-duration
       :volume (etaf-ncm--ref session :volume-ref)
       :shuffle (etaf-ncm--ref session :shuffle-ref)
       :liked (etaf-ncm--ref session :liked-ref)
       :repeat (etaf-ncm--ref session :repeat-ref)
       :message (etaf-ncm--ref session :message)
       :lyrics lyrics-visible
       :queue-count queue-count
       :on-toggle on-toggle
       :on-next on-next
       :on-previous on-previous
       :on-stop on-stop
       :on-like on-like
       :on-add on-add
       :on-lyrics on-lyrics
       :on-queue on-queue
       :on-cover on-cover
       :on-volume on-volume
       :on-seek on-seek
       :on-shuffle on-shuffle
       :on-repeat on-repeat))
    ;; The full-page view of the playing song: one picture and one panel over
    ;; the whole window.  It paints every cell itself, so the player beneath
    ;; stays mounted and closing the page damages nothing but this layer.
    (box :if (etaf-ncm--active-value now-visible)
         :position 'absolute :left '(px 0) :top '(lh 0)
         :width '(% 100) :height '(% 100) :z-index 5
      (etaf-ncm--view-now
       :title track-title :artist track-artist :album selected-album
       :cover (etaf-value cover-file) :hero (etaf-value hero)
       :spectrum (etaf-ncm--ref session :spectrum)
       :accent (or (etaf-value hero-accent) (etaf-ncm-color :accent))
       :panel (etaf-ncm-color :bg)
       :playing playing
       :liked (etaf-ncm--ref session :liked-ref)
       :elapsed position :duration track-duration
       :projection now-lyric
       :geometry (etaf-value now-geometry)
       :sections (etaf-value now-sections)
       :on-back on-back :on-toggle on-toggle
       :on-next on-next :on-previous on-previous
       :on-like on-like :on-seek on-seek))))

(defun etaf-ncm-view (&optional model)
  "Return the player View for MODEL.
MODEL defaults to a new session, exactly as `etaf-ncm-open' creates one; pass a
session from `etaf-ncm-create' to embed the player in your own mount."
  (etaf-view (etaf-ncm-app :model (or model (etaf-ncm-create)))))

(defun etaf-ncm--list-highlights (app)
  "Return APP's (SELECTION-LINE . PLAYING-LINE) inside the visible page.
Lines count from zero; -1 keeps that bar clipped off the page."
  (let* ((slots (plist-get app :row-slots))
         (size (min (max 1 (etaf-ncm--render-rows app)) (length slots)))
         (selection (etaf-ncm--read app :selection))
         (played (plist-get (etaf-ncm--read app :status) :song-id))
         (playing -1))
    (dotimes (index size)
      (let ((value (etaf-value (aref slots index))))
        (when (and value played (equal (plist-get value :id) played))
          (setq playing index))))
    (cons (if (and (>= selection 0) (< selection size)) selection -1)
          playing)))

(defun etaf-ncm--apply-highlight-geometry (app host line)
  "Move APP's HOST bar to LINE through the retained geometry boundary.
One `:top' translation repaints only the damaged rows of the list plane."
  (when-let* ((buffer (plist-get app :buffer))
              ((buffer-live-p buffer))
              (runtime (etaf-runtime-for-buffer buffer))
              ((numberp line)))
    (ignore-errors
      (etaf-runtime-update-host-geometry runtime host :top (list 'lh line)))))

(defun etaf-ncm--apply-list-highlights (app &optional lines)
  "Move APP's highlight bars to LINES, defaulting to the current page.
Each bar is one retained host geometry update: a `:top' translation that
never republishes the list plane."
  (let ((lines (or lines (plist-get app :highlight-lines))))
    (when lines
      (etaf-ncm--apply-highlight-geometry app 'ncm-list-selection (car lines))
      (etaf-ncm--apply-highlight-geometry app 'ncm-list-playing (cdr lines))
      (etaf-ncm--reveal-selection app))))

(defun etaf-ncm--schedule-list-highlights (app lines)
  "Move APP's highlight bars to LINES.
Line changes are the only reason to schedule: a slot write that leaves both
bars where they are must not publish geometry.  With animation targets, the
shared clock slides each bar from where it is, and the move stays outside the
reactive batch that reported the change; a model without targets (for example
a session driven headlessly) applies the geometry at once."
  (unless (equal lines (plist-get app :highlight-lines))
    (setf (plist-get app :highlight-lines) lines)
    (let ((targets (plist-get app :highlight-targets)))
      (if targets
          (etaf-batch
            (etaf-set-value (car targets) (car lines))
            (etaf-set-value (cdr targets) (cdr lines)))
        (etaf-ncm--apply-list-highlights app lines)))))

(defun etaf-ncm--fit-fringe (window)
  "Give WINDOW the right fringe its character cells do not cover.
The canvas paints whole cells, so a window whose width is not a multiple of the
cell leaves a strip no row reaches.  Ebox reads that strip as fringe: with a
right fringe it lays the tree out across the whole window, and without one it
keeps a cell back for the truncation glyph.  A fringe as wide as the remainder
therefore both covers the strip and lets the tree use the rest.

Measured from the window, not from the body: the body already leaves the current
fringe out, so using it feeds each result into the next and widens the fringe
until it eats a row of cells."
  (when (and window (window-live-p window) (display-graphic-p))
    (let* ((buffer (window-buffer window))
           (left (car (window-fringes window)))
           ;; The remainder is measured in the cells the canvas draws with, so
           ;; the fringe absorbs exactly the strip the text cannot fill.
           (cell (or (and (etaf-runtime-for-buffer buffer)
                          (plist-get (etaf-ncm--display-metrics buffer) :char-width))
                     (frame-char-width (window-frame window))))
           (width (- (window-pixel-width window) left))
           (rest (and (> cell 0) (mod width cell))))
      (ignore-errors
        (set-window-fringes window left rest nil t))
      ;; The fringe is page, not decoration: it continues the row beside it,
      ;; so it takes the page's own background instead of the theme's.
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (face-remap-set-base 'fringe :background (etaf-ncm-color :bg)))))))

(defun etaf-ncm-open (&optional model)
  "Open the NetEase Cloud Music player and return its buffer.
MODEL defaults to a session from `etaf-ncm-create', so the player opens on the
daily recommendation with the signed-in account, queue and playback status of
the backend.  A caller-provided MODEL keeps its library, queue and selection."
  (interactive)
  (when (and (called-interactively-p 'interactive)
             (null model)
             (fboundp 'etaf-ncm-doctor))
    (let ((missing (cl-remove-if #'cadr (plist-get (etaf-ncm-doctor) :required))))
      (when missing
        (user-error "etaf-ncm requires %s: %s (run M-x etaf-install-doctor for install commands)"
                    (mapconcat #'car missing ", ")
                    (nth 2 (car missing))))))
  (let* ((model (or model (etaf-ncm-create)))
         ;; Ebox paints whole character cells, so a window body that is not
         ;; a whole number of cells keeps a sub-cell remainder at its edge;
         ;; the canvas background shows the palette there.  ETAF chooses the
         ;; display-safe viewport from the visible window, so the player
         ;; passes no geometry of its own.
         (buffer (etaf-app-open
                  etaf-ncm-buffer-name (etaf-ncm-view model)
                  :state model
                  ;; The mode line stays: it is where a reader looks for the
                  ;; buffer's name, and hiding it made the player feel like a
                  ;; separate application rather than a buffer in this session.
                  :mode-line t
                  :background (lambda () (plist-get (etaf-ncm--read model :theme) :ui-bg))
                  ;; Mount-time focus and highlight work reads the buffer.
                  :on-fit (lambda (window)
                            (plist-put model :buffer (current-buffer))
                            (etaf-ncm--fit-fringe window)))))
    (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
    (etaf-ncm--apply-list-highlights model (etaf-ncm--list-highlights model))
    buffer))

(defun etaf-ncm-close ()
  "Unmount the player and kill its buffer."
  (interactive)
  (when (etaf-app-state etaf-ncm-buffer-name)
    (etaf-app-close etaf-ncm-buffer-name)))

(defun etaf-ncm-quit ()
  "Stop the backend player and close the client.
Unlike `etaf-ncm-close', which only closes the window and lets the backend
keep playing, quitting ends the playback too: the stop runs before the
buffer is killed, so a later `etaf-ncm-open' starts from a stopped player.
The backend keeps its queue files, so `back' can still bring the queue
back."
  (interactive)
  (setq etaf-ncm--player-owner nil)
  (when-let* ((model (or etaf-ncm--model (etaf-app-state etaf-ncm-buffer-name))))
    (etaf-ncm--stop-synchronously (etaf-ncm--client model)))
  (etaf-ncm-close))

;; The backend player is an external mpv process: exiting Emacs must not
;; leave it playing.  The hook only stops a player this Emacs started (see
;; `etaf-ncm--player-owner'), so playback the CLI started keeps running.
(add-hook 'kill-emacs-hook #'etaf-ncm--stop-player-on-exit)

(provide 'etaf-ncm-app)
;;; etaf-ncm-app.el ends here
