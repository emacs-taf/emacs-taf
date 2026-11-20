;;; etaf-ncm-tests.el --- Acceptance tests for etaf-ncm -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour tests.  Every scenario drives the player through the
;; interfaces declared in `etaf-ncm.el' with a scripted client, so no test needs
;; the network, mpv or a graphical frame: the backend is a plain function that
;; answers in fixtures shaped like the real JSON.

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ncm)

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file and its fixtures.")

(defconst etaf-ncm-tests--shell-entry-p
  (not (eq system-type 'windows-nt))
  "Whether this system runs the backend's shell entry.
Windows does not: its `bash.exe' launches WSL, which reads the Windows path
the script is called with as a relative name.  The requests Windows needs
are served by `netease-cli.mjs', which is plain Node.")

(defvar etaf-ncm-tests--requests nil
  "Requests received by the scripted client, newest first.")

(defvar etaf-ncm-tests--status nil
  "Playback status document the scripted client reports.")

(defvar etaf-ncm-tests--error nil
  "When non-nil, the scripted client fails every request with this message.")

(defun etaf-ncm-tests--fixture (name)
  "Return fixture NAME from tests/fixtures as a plist."
  (let ((file (expand-file-name (format "fixtures/%s.json" name)
                                etaf-ncm-tests--directory)))
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'plist :array-type 'list
                         :null-object nil :false-object nil))))

(defun etaf-ncm-tests--reply (callback data)
  "Answer CALLBACK with DATA, or with the scripted failure."
  (funcall callback
           (if etaf-ncm-tests--error
               (list :error etaf-ncm-tests--error :hint "scripted")
             (list :ok data))))

(defun etaf-ncm-tests--client (request callback)
  "Answer REQUEST on CALLBACK from fixtures, recording it first."
  (push request etaf-ncm-tests--requests)
  (let ((resource (plist-get request :resource)))
    (etaf-ncm-tests--reply
     callback
     (pcase (plist-get request :op)
       (:browse
        (etaf-ncm-tests--fixture
         (pcase resource
           (:playlists "playlists")
           (:charts "charts")
           (:albums "albums")
           (:artists "artists")
           (:podcasts "podcasts")
           (_ "daily"))))
       (:search (etaf-ncm-tests--fixture
                 (if (eq resource :playlists) "search-playlists" "search")))
       (:lyric (etaf-ncm-tests--fixture "lyric"))
       (:session (etaf-ncm-tests--fixture "session"))
       (:liked-ids (etaf-ncm-tests--fixture "liked-ids"))
       (:downloads
        (list :count 1 :total 1
              :downloads (list (list :id 1 :name "曲目 1" :artist "歌手 1"
                                     :file "/tmp/曲目 1.flac" :level "lossless"
                                     :br 1000 :bytes 10 :at "2026-10-03T00:00:00+0800"))))
       (:download
        (let ((id (plist-get request :id)))
          (list :id id :name (format "曲目 %s" id) :artist "歌手"
                :file (format "/tmp/曲目 %s.flac" id) :level "lossless"
                :br 1000 :bytes 10 :at "2026-10-03T00:00:00+0800")))
       (:status (or etaf-ncm-tests--status (etaf-ncm-tests--fixture "status")))
       (:queue (append (etaf-ncm-tests--fixture "queue")
                       (list :songs (plist-get (etaf-ncm-tests--fixture "queue-tracks")
                                               :songs))))
       (_ (list :ok t))))))

(defun etaf-ncm-tests--session (&optional client)
  "Return a player session driven by the scripted CLIENT."
  (etaf-ncm-create :client (or client #'etaf-ncm-tests--client)))

(defun etaf-ncm-tests--request (op)
  "Return the newest recorded request whose `:op' is OP."
  (seq-find (lambda (request) (eq (plist-get request :op) op))
            etaf-ncm-tests--requests))

(defun etaf-ncm-tests--rows (app)
  "Return APP's library rows."
  (plist-get (etaf-ncm-state app) :items))

(defvar etaf-ncm-tests--poll-interval 3600
  "Playback polling interval used by mounted acceptance sessions.")

(defmacro etaf-ncm-tests--with-player (app &rest body)
  "Open APP in an isolated buffer and a roomy window while running BODY."
  (declare (indent 1) (debug t))
  `(let ((etaf-ncm-buffer-name (generate-new-buffer-name " *ncm-acceptance*"))
         (etaf-ncm-status-interval etaf-ncm-tests--poll-interval)
         (display-buffer-overriding-action '((display-buffer-same-window)))
         (frame (selected-frame))
         (width (frame-width))
         (height (frame-height)))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (set-frame-size frame 180 48)
           (etaf-ncm-open ,app)
           ,@body)
       (etaf-ncm-close)
       (set-frame-size frame width height))))

(ert-deftest etaf-ncm-tests-new-session-is-headless ()
  "A new session starts on the daily library without touching the backend."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (should (eq (plist-get (etaf-ncm-state app) :section) :daily))
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))
    (should (eq (plist-get (etaf-ncm-state app) :layout) 'wide))
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 0))
    (should-not etaf-ncm-tests--requests)))

(ert-deftest etaf-ncm-tests-refresh-loads-library-and-playback ()
  "Refreshing loads the library, the account, the playback truth and the queue."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app))))
    (should (= (plist-get state :rows-total) 12))
    (should (equal (plist-get state :title) "每日推荐"))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :name) "曲目 1"))
    (should (= (plist-get (nth 0 (plist-get state :items)) :id) 1))
    (should (equal (plist-get (nth 1 (plist-get state :items)) :badge) "VIP"))
    (should (equal (plist-get state :message) "每日推荐 · 12 项"))
    (should (equal (plist-get (plist-get state :account) :nick) "听众"))
    (should (eq (plist-get (plist-get state :status) :state) 'playing))
    (should (= (plist-get (plist-get state :status) :queue-pos) 2))
    (should (= (plist-get (plist-get state :status) :queue-count) 5))
    (should (= (length (plist-get state :visible))
                (min (plist-get state :page-size) (plist-get state :rows-total))))
    (should (memq :browse (mapcar (lambda (request) (plist-get request :op))
                                 etaf-ncm-tests--requests)))))

(ert-deftest etaf-ncm-tests-refresh-keeps-selection-inside-the-list ()
  "Loading a library resets the selection to its first row."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 6)
    (etaf-ncm-locate app :charts)
    (let ((state (etaf-ncm-state app)))
      (should (= (plist-get state :rows-total) 10))
      (should (equal (plist-get state :title) "排行榜"))
      (should (= (plist-get state :selection) 0))
      (should (equal (plist-get (nth 0 (plist-get state :items)) :kind) :chart)))))

(ert-deftest etaf-ncm-tests-locate-rejects-unknown-library ()
  "An unknown library signals `etaf-ncm-error' and leaves the session alone."
  (let* ((app (etaf-ncm-tests--session))
         (before (plist-get (etaf-ncm-state app) :section)))
    (should-error (etaf-ncm-locate app :nowhere) :type 'etaf-ncm-error)
    (should (eq (plist-get (etaf-ncm-state app) :section) before))))

(ert-deftest etaf-ncm-tests-sections-inventory-is-navigable ()
  "Every section in `etaf-ncm-sections' is accepted by `etaf-ncm-locate'."
  (let ((app (etaf-ncm-tests--session)))
    (dolist (group etaf-ncm-sections)
      (should (symbolp (car group)))
      (dolist (entry (cdr group))
        (should (= (length entry) 3))
        (etaf-ncm-locate app (nth 0 entry))
        (should (eq (plist-get (etaf-ncm-state app) :section) (nth 0 entry)))
        (should (equal (plist-get (etaf-ncm-state app) :title) (nth 1 entry)))))))

(ert-deftest etaf-ncm-tests-search-records-keyword-and-scope ()
  "Searching shows results and sends the keyword with its scope."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-search app "  关键词  ") (etaf-ncm-state app)))
         (request (etaf-ncm-tests--request :search)))
    (should (equal (plist-get state :mode) 'search))
    (should (equal (plist-get state :query) "关键词"))
    (should (equal (plist-get state :title) "搜索结果"))
    (should (= (plist-get state :rows-total) 12))
    (should (equal (plist-get request :keyword) "关键词"))
    (should (eq (plist-get request :scope) 'song))
    (should-error (etaf-ncm-search app "   ") :type 'etaf-ncm-error)
    (etaf-ncm-search app "关键词" 'playlist)
    (should (eq (plist-get (etaf-ncm-tests--request :search) :scope) 'playlist))
    (should (equal (plist-get (etaf-ncm-state app) :title) "搜索结果"))))

(ert-deftest etaf-ncm-tests-play-uses-the-selected-row ()
  "Playing a selection starts on its loaded id without a follow-up jump."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 2)
    (etaf-ncm-activate-selection app)
    (let ((request (etaf-ncm-tests--request :play)))
      (should (equal (plist-get request :target) (list :kind :daily)))
      (should (= (plist-get request :start) 3))
      (should (= (nth 2 (plist-get request :ids)) 3))
      (should-not (etaf-ncm-tests--request :jump))
      (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：曲目 3")))
    (etaf-ncm-play app)
    (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：每日推荐"))))

(ert-deftest etaf-ncm-tests-play-accepts-rows-ids-and-keywords ()
  "Play resolves library rows, song ids and search keywords."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-play app (nth 0 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :daily)))
    (should (= (plist-get (etaf-ncm-tests--request :play) :start) 1))
    (etaf-ncm-play app 42)
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :song :id 42)))
    (etaf-ncm-play app "  陈粒 ")
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :query :id "陈粒")))
    (etaf-ncm-locate app :playlists)
    (etaf-ncm-play app (nth 1 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :playlist :id 1002)))
    (should-error (etaf-ncm-play app '(:kind :nonsense :id 1)) :type 'etaf-ncm-error)))

(ert-deftest etaf-ncm-tests-add-to-queue-takes-songs-only ()
  "Queueing accepts a song row and rejects a playlist row."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-add-to-queue app (nth 4 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :add) :id) 5))
    (should (equal (plist-get (nth 4 (etaf-ncm-tests--rows app)) :name) "曲目 5"))
    (should (equal (plist-get (etaf-ncm-state app) :message) "已加入队列：曲目 5"))
    (etaf-ncm-locate app :playlists)
    (should-error (etaf-ncm-add-to-queue app (nth 0 (etaf-ncm-tests--rows app)))
                  :type 'etaf-ncm-error)))

(ert-deftest etaf-ncm-tests-transport-commands-reach-the-backend ()
  "Transport, volume, seek, mode and like commands send their own request."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-toggle-playback app)
    (should (etaf-ncm-tests--request :toggle))
    (etaf-ncm-next-track app)
    (should (etaf-ncm-tests--request :next))
    (etaf-ncm-previous-track app)
    (should (etaf-ncm-tests--request :previous))
    (etaf-ncm-stop app)
    (should (etaf-ncm-tests--request :stop))
    (etaf-ncm-set-volume app 63.4)
    (should (= (plist-get (etaf-ncm-tests--request :volume) :value) 63))
    (should (equal (plist-get (etaf-ncm-state app) :message) "音量 63"))
    (should-error (etaf-ncm-set-volume app 131) :type 'etaf-ncm-error)
    (should-error (etaf-ncm-set-volume app -1) :type 'etaf-ncm-error)
    (etaf-ncm-seek app -15)
    (should (= (plist-get (etaf-ncm-tests--request :seek) :seconds) -15))
    (etaf-ncm-set-shuffle app t)
    (should (eq (plist-get (etaf-ncm-tests--request :shuffle) :on) t))
    (etaf-ncm-set-repeat app nil)
    (should (eq (plist-get (etaf-ncm-tests--request :repeat) :on) nil))
    (should (equal (plist-get (etaf-ncm-state app) :message) "列表循环：关"))
    (etaf-ncm-set-repeat app t)
    (should (eq (plist-get (etaf-ncm-tests--request :repeat) :on) t))
    (should (equal (plist-get (etaf-ncm-state app) :message) "列表循环：开"))
    (etaf-ncm-like app)
    (should (etaf-ncm-tests--request :like))
    (etaf-ncm-like app t)
    (should (etaf-ncm-tests--request :unlike))
    (etaf-ncm-jump-queue app 3)
    (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 3))))

(ert-deftest etaf-ncm-tests-liked-table-decides-the-heart ()
  "The playing song's heart follows the liked-song id table.
The backend status carries no like field, so the table decides it once it
arrived, and liking a song keeps the session table in step."
  (let ((etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--status nil))
    (let ((app (etaf-ncm-tests--session)))
      (etaf-ncm-refresh app)
      (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :liked) t))
      ;; A song outside the table shows the hollow heart.
      (setq etaf-ncm-tests--status
            (append (list :song_id "2" :title "曲目 2")
                    (etaf-ncm-tests--fixture "status")))
      (etaf-ncm-refresh app)
      (should-not (plist-get (plist-get (etaf-ncm-state app) :status) :liked))
      ;; Liking it adds it to the session table and survives the next status.
      (etaf-ncm-like app)
      (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :liked) t))
      (etaf-ncm-refresh app)
      (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :liked) t)))))

(ert-deftest etaf-ncm-tests-selection-clamps-at-both-ends ()
  "Selection stops at the first and last loaded row."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app -1)
    (should (= (plist-get (etaf-ncm-state app) :selection) 0))
    (etaf-ncm-move-selection app 100)
    (should (= (plist-get (etaf-ncm-state app) :selection) 11))
    (etaf-ncm-move-selection app -100)
    (should (= (plist-get (etaf-ncm-state app) :selection) 0))))

(ert-deftest etaf-ncm-tests-toggle-aside-switches-panels ()
  "The side panel alternates between the lyric and the queue."
  (let ((app (etaf-ncm-tests--session)))
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
    (etaf-ncm-toggle-aside app)
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'queue))
    (etaf-ncm-toggle-aside app)
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))))

(ert-deftest etaf-ncm-tests-show-pane-selects-the-visible-pane ()
  "SHOW-PANE records the pane and rejects an unknown one."
  (let ((app (etaf-ncm-tests--session)))
    (should (eq (etaf-ncm-show-pane app 'aside) 'aside))
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
    (should (eq (etaf-ncm-show-pane app 'list) 'list))
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))
    (should-error (etaf-ncm-show-pane app 'queue) :type 'etaf-ncm-error)
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))))

(ert-deftest etaf-ncm-tests-wide-layout-remembers-the-pane ()
  "A pane chosen in a wide layout stays chosen until the viewport changes."
  (let ((app (etaf-ncm-tests--session))
        (buffer (get-buffer-create " *etaf-ncm-tests-wide-pane*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-ncm-view app)
                      (list :viewport-width 1600 :viewport-height 40))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-runtime-flush runtime)
            (should (eq (plist-get (etaf-ncm-state app) :layout) 'wide))
            (etaf-ncm-show-pane app 'aside)
            (etaf-runtime-flush runtime)
            (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
            (etaf-ncm-show-pane app 'list)
            (etaf-runtime-flush runtime)
            (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))))
      (kill-buffer buffer))))

(ert-deftest etaf-ncm-tests-queue-and-lyric-follow-playback ()
  "The snapshot reports the queue around the playing song and the lyric line."
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app)))
         (queue (plist-get state :queue))
         (lyric (plist-get state :lyric)))
    (should (= (plist-get queue :count) 5))
    (should (= (plist-get queue :pos) 2))
    (should (= (length (plist-get queue :songs)) 5))
    (should (equal (plist-get (plist-get queue :current) :name) "曲目 2"))
    (should (= (plist-get lyric :lines) 6))
    (should (= (plist-get lyric :index) 6))
    (should (equal (plist-get state :lyric-line) "第五行歌词"))))

(ert-deftest etaf-ncm-tests-parse-lyric-reads-lrc ()
  "LRC parsing keeps the tagged lines in order and ignores noise."
  (let ((lines (etaf-ncm-parse-lyric
                (concat "[al:专辑]\n"
                        "[00:05.00] 第二句\n"
                        "[00:01.50]第一句\n"
                        "[00:10.00][00:12.25] 重复句\n"
                        "没有时间戳\n"))))
    (should (equal (mapcar #'cdr lines) '("第一句" "第二句" "重复句" "重复句")))
    (should (equal (mapcar #'car lines) '(1.5 5.0 10.0 12.25)))
    (should-not (etaf-ncm-parse-lyric ""))
    (should-not (etaf-ncm-parse-lyric nil))))

(ert-deftest etaf-ncm-tests-backend-failure-is-reported-not-signaled ()
  "A failing request lands in the session error instead of raising."
  (let* ((etaf-ncm-tests--error "后端不可用")
         (app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (let ((state (etaf-ncm-state app)))
      (should (equal (plist-get state :error) "后端不可用"))
      (should-not (plist-get state :loading))
      (should (zerop (plist-get state :rows-total)))
      (should (string-prefix-p "后端不可用" (plist-get state :message))))))

(ert-deftest etaf-ncm-tests-missing-backend-is-reported-not-signaled ()
  "A backend whose scripts are absent reports an error instead of raising."
  (let ((app (etaf-ncm-create :client (etaf-ncm-make-client
                                       :backend-directory "/nonexistent-etaf-ncm-backend"))))
    (etaf-ncm-refresh app)
    (let ((state (etaf-ncm-state app)))
      (should (string-match-p "missing" (or (plist-get state :error) "")))
      (should (string-match-p "missing" (plist-get state :message)))
      (should-not (plist-get state :loading)))))

(ert-deftest etaf-ncm-tests-backend-refusal-reports-its-own-message ()
  "A refused backend command reports its own error and hint.
The netease-music scripts exit non-zero with a report on stderr: the shell
entry writes `error=' and `hint=' lines, the mpv bridge writes a JSON object.
Both must reach the caller as the message, and a crash without a report keeps
the exit status as the message."
  (skip-unless etaf-ncm-tests--shell-entry-p)
  (let* ((directory (make-temp-file "etaf-ncm-refusal-backend" t))
         (scripts (expand-file-name "scripts" directory))
         (script (expand-file-name "netease-music.sh" scripts)))
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file script
            (insert "#!/bin/sh\n"
                    "case \"$1\" in\n"
                    "  play) printf 'error=notfound\\nhint=选中的这首不能播（可能要 VIP 或没有版权），队列未替换\\n' >&2; exit 4;;\n"
                    "  next) printf '{\"error\":\"external\",\"hint\":\"mpv 连不上（先 play 一下）\"}\\n' >&2; exit 1;;\n"
                    "  prev) printf 'boom\\n' >&2; exit 3;;\n"
                    "esac\n"
                    "exit 1\n"))
          (set-file-modes script #o755)
          ;; Playing, next and previous run through the Node entry, so it has
          ;; to refuse in the same three ways the shell entry does.
          (with-temp-file (expand-file-name "netease-cli.mjs" scripts)
            (insert "#!/usr/bin/env node\n"
                    "const args = process.argv.slice(2);\n"
                    "if (args[0] === 'play') {\n"
                    "  process.stderr.write('error=notfound\\nhint=选中的这首不能播（可能要 VIP 或没有版权），队列未替换\\n');\n"
                    "  process.exit(4);\n"
                    "}\n"
                    "if (args[0] === 'next') {\n"
                    "  process.stderr.write(JSON.stringify({error: 'external',"
                    " hint: 'mpv 连不上（先 play 一下）'}) + '\\n');\n"
                    "  process.exit(1);\n"
                    "}\n"
                    "if (args[0] === 'prev') {\n"
                    "  process.stderr.write('boom\\n');\n"
                    "  process.exit(3);\n"
                    "}\n"
                    "process.exit(1);\n"))
          (set-file-modes (expand-file-name "netease-cli.mjs" scripts) #o755)
          (let* ((client (etaf-ncm-make-client :backend-directory directory :timeout 10))
                 (ask (lambda (request)
                        (let (reply (deadline (+ (float-time) 10)))
                          (etaf-ncm-client-call client request (lambda (result) (setq reply result)))
                          (while (and (null reply) (< (float-time) deadline))
                            (accept-process-output nil 0.05))
                          reply))))
            (let ((refusal (funcall ask (list :op :play :target (list :kind :song :id 42)))))
              (should (equal (car refusal) :error))
              (should (equal (cadr refusal) "选中的这首不能播（可能要 VIP 或没有版权），队列未替换"))
              (should (equal (plist-get (cddr refusal) :code) "notfound")))
            (let ((bridge (funcall ask (list :op :next))))
              (should (equal (car bridge) :error))
              (should (equal (cadr bridge) "mpv 连不上（先 play 一下）"))
              (should (equal (plist-get (cddr bridge) :code) "external")))
            (let ((crash (funcall ask (list :op :previous))))
              (should (equal (car crash) :error))
              (should (string-prefix-p "Backend command failed" (cadr crash)))
              (should (equal (plist-get (cddr crash) :hint) "boom")))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-login-reads-phone-and-code-in-the-minibuffer ()
  "The login command asks for the phone number and the SMS code.
The phone prompt may reuse the number the backend remembers; the code prompt
only appears once the backend reports the message went out.  Both backend
steps carry the caller's values, and a success reloads the player."
  (setq etaf-ncm-tests--requests nil)
  (let* ((client (lambda (request callback)
                   (pcase (plist-get request :op)
                     (:login-sms
                      (push request etaf-ncm-tests--requests)
                      (funcall callback (list :ok (list :conclusion "验证码已发到 138****0000"))))
                     (:login-sms-code
                      (push request etaf-ncm-tests--requests)
                      (funcall callback (list :ok (list :nick "甲" :uid 7))))
                     (_ (etaf-ncm-tests--client request callback)))))
         (app (etaf-ncm-tests--session client))
         (answers '("13800000000" "123456"))
         (asked nil))
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (push prompt asked)
                 (pop answers))))
      (etaf-ncm-login app))
    (should (equal (mapcar (lambda (request) (plist-get request :phone))
                           (list (etaf-ncm-tests--request :login-sms)
                                 (etaf-ncm-tests--request :login-sms-code)))
                   '("13800000000" "13800000000")))
    (should (equal (plist-get (etaf-ncm-tests--request :login-sms-code) :code) "123456"))
    (should (equal asked '("短信验证码（收到后输入）：" "手机号：")))
    (should (etaf-ncm-tests--request :browse))
    (should-not (plist-get (etaf-ncm-state app) :error))))

(ert-deftest etaf-ncm-tests-login-rejects-a-blank-phone () 
  "A blank phone number stops before any backend request."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (answers '("")))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (pop answers))))
      (should-error (etaf-ncm-login app) :type 'user-error))
    (should-not (etaf-ncm-tests--request :login-sms))))

(ert-deftest etaf-ncm-tests-failure-banner-outlives-status-polls ()
  "A failure stays in the banner through routine polls and clears on a success.
The status timer is not user action: it must not wipe the message the reader
still has to act on."
  (setq etaf-ncm-tests--requests nil)
  (let* ((etaf-ncm-status-interval 0.05)
         (etaf-ncm-idle-poll-interval 0.05)
         (etaf-ncm-buffer-name " *etaf-ncm-tests-banner*")
         (fail t)
         (auth-browse nil)
         (client (lambda (request callback)
                   (pcase (plist-get request :op)
                     (:play (if fail
                                (funcall callback
                                         (list :error "选中的这首不能播（可能要 VIP 或没有版权），队列未替换"
                                               :code "notfound"))
                              (funcall callback (list :ok (list)))))
                     (:browse (if auth-browse
                                  (funcall callback (list :error "登录已过期或未登录：跑 netease-music.sh login --sms <手机号>" :code "auth"))
                                (etaf-ncm-tests--client request callback)))
                     (_ (etaf-ncm-tests--client request callback)))))
         (app (etaf-ncm-tests--session client)))
    (unwind-protect
        (progn
          (etaf-ncm-open app)
          (etaf-ncm-refresh app)
          (should (etaf-ncm-tests--wait (lambda () (etaf-ncm-tests--request :status))))
          ;; A failed play puts the reason on display.
          (etaf-ncm-press-row app 1)
          (should (etaf-ncm-tests--wait
                   (lambda ()
                     (equal (plist-get (etaf-ncm-state app) :error)
                            "选中的这首不能播（可能要 VIP 或没有版权），队列未替换"))))
          ;; Routine status polls keep it on display.
          (accept-process-output nil 0.3)
          (should (equal (plist-get (etaf-ncm-state app) :error)
                         "选中的这首不能播（可能要 VIP 或没有版权），队列未替换"))
          ;; A successful action clears it.
          (setq fail nil)
          (etaf-ncm-press-row app 1)
          (should (etaf-ncm-tests--wait (lambda () (null (plist-get (etaf-ncm-state app) :error)))))
          ;; An expired login names the in-player way out.
          (setq auth-browse t)
          (etaf-ncm-locate app :fm)
          (should (etaf-ncm-tests--wait
                   (lambda ()
                     (equal (plist-get (etaf-ncm-state app) :message)
                            "登录已过期：按 L 用短信验证码重新登录")))))
      (etaf-ncm-close))))

(ert-deftest etaf-ncm-tests-error-banner-shows-the-whole-message ()
  "A long failure is wrapped in the banner, not clipped to the bar's slot."
  (setq etaf-ncm-tests--requests nil)
  (let* ((long "选中的这首不能播（可能要 VIP 或没有版权），队列没有替换；换一首能播的，或者按 g 刷新看看")
         (client (lambda (request callback)
                   (pcase (plist-get request :op)
                     (:browse (funcall callback (list :error long :code "external")))
                     (_ (etaf-ncm-tests--client request callback)))))
         (app (etaf-ncm-tests--session client))
         (buffer (get-buffer-create " *etaf-ncm-tests-banner-text*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-ncm-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (should (etaf-ncm-tests--wait
                   (lambda () (equal (plist-get (etaf-ncm-state app) :error) long))))
          (with-current-buffer buffer
            (let ((text (replace-regexp-in-string
                         "[ \t\n]+" ""
                         (buffer-substring-no-properties (point-min) (point-max)))))
              (should (string-match-p (regexp-quote "按g刷新看看") text)))))
      (kill-buffer buffer))))

(ert-deftest etaf-ncm-tests-client-call-reaches-a-function-client ()
  "The documented client protocol works with a plain function."
  (let (seen)
    (etaf-ncm-client-call (lambda (request callback)
                            (setq seen request)
                            (funcall callback (list :ok (list :op t))))
                          (list :op :status)
                          (lambda (reply) (setq seen (list reply seen))))
    (should (equal seen '((:ok (:op t)) (:op :status))))
    (etaf-ncm-cancel (lambda (_request _callback) nil))))

(ert-deftest etaf-ncm-tests-player-requests-run-the-node-entry ()
  "Every request a playing session makes runs netease-cli.mjs, not a shell.
A stub entry records the command line, so a request that translates into the
wrong argument (a keyword instead of the song id, say) fails here instead of
silently doing nothing against the real backend."
  (skip-unless (executable-find etaf-ncm-node-program))
  (let* ((directory (make-temp-file "etaf-ncm-backend" t))
         (scripts (expand-file-name "scripts" directory))
         (cli (expand-file-name "netease-cli.mjs" scripts))
         (log (expand-file-name "calls.log" directory))
         reply)
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file cli
            (insert "import { appendFileSync } from 'node:fs';\n"
                    (format "appendFileSync(%s, process.argv.slice(2).join(' ') + '\\n');\n"
                            (prin1-to-string log))
                    "console.log(JSON.stringify({ ok: true, state: 'playing' }));\n"))
          (let ((client (etaf-ncm-make-client :backend-directory directory :timeout 15)))
            (dolist (case '(((:op :play :target (:kind :song :id 4242))
                             "play 4242 --json")
                            ((:op :play :target (:kind :fm) :ids (7 2 7) :start 3)
                             "play-ids 7,2,7 --start 3 --json")
                            ((:op :jump :index 3) "jump 3 --json")
                            ((:op :volume :value 60) "volume 60 --json")
                            ((:op :seek :seconds -10) "seek -10 --json")
                            ((:op :shuffle :on t) "shuffle on --json")
                            ((:op :cover :id 42 :file "art.png")
                             "cover 42 --download art.png --force --json")))
              (setq reply nil)
              (etaf-ncm-client-call client (car case) (lambda (result) (setq reply result)))
              (let ((deadline (+ (float-time) 15)))
                (while (and (null reply) (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (should (eq (car-safe reply) :ok))
              (should (with-temp-buffer
                        (insert-file-contents log)
                        (string-match-p (concat (regexp-quote (cadr case)) "$")
                                        (buffer-string)))))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-shell-entry-keeps-the-queue-snapshots ()
  "Queue snapshots still run the POSIX shell entry, with its own arguments."
  (skip-unless etaf-ncm-tests--shell-entry-p)
  (let* ((directory (make-temp-file "etaf-ncm-shell" t))
         (scripts (expand-file-name "scripts" directory))
         (script (expand-file-name "netease-music.sh" scripts))
         (log (expand-file-name "calls.log" directory))
         reply)
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file script
            (insert "#!/bin/sh\n"
                    (format "printf '%%s\\n' \"$*\" >> %s\n" (shell-quote-argument log))
                    "printf '{\"ok\": true}\\n'\n"))
          (set-file-modes script #o755)
          (let ((client (etaf-ncm-make-client :backend-directory directory :timeout 15)))
            (etaf-ncm-client-call client (list :op :queue-save :name "晚上")
                                  (lambda (result) (setq reply result)))
            (let ((deadline (+ (float-time) 15)))
              (while (and (null reply) (< (float-time) deadline))
                (accept-process-output nil 0.05)))
            (should (eq (car-safe reply) :ok))
            (should (with-temp-buffer
                      (insert-file-contents log)
                      (string-match-p "queue-save 晚上 --json --quiet" (buffer-string))))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-login-runs-the-node-entry-not-a-shell ()
  "A sign-in is one Node program on every system, never a shell script.
The stub backend ships only `netease-cli.mjs', so a request that went through
`netease-music.sh' could not answer at all.  Windows has no native `bash',
and the `bash.exe' it does have launches WSL, which cannot read the Windows
path the script is called with: that is how a sign-in ended at exit 127 with
no SMS sent and no code asked for."
  (skip-unless (executable-find etaf-ncm-node-program))
  (let* ((directory (make-temp-file "etaf-ncm-login" t))
         (scripts (expand-file-name "scripts" directory))
         (cli (expand-file-name "netease-cli.mjs" scripts))
         (log (expand-file-name "calls.log" directory))
         reply)
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file cli
            (insert "import { appendFileSync } from 'node:fs';\n"
                    (format "appendFileSync(%s, process.argv.slice(2).join(' ') + '\\n');\n"
                            (prin1-to-string log))
                    "console.log(JSON.stringify({ ok: true, conclusion: 'sent' }));\n"))
          (let ((client (etaf-ncm-make-client :backend-directory directory :timeout 15)))
            (dolist (case '(((:op :login-sms :phone "13800000000")
                             "login --sms 13800000000 --json")
                            ((:op :login-sms-code :phone "13800000000" :code "123456")
                             "login --sms 13800000000 --sms-code 123456 --json")))
              (setq reply nil)
              (etaf-ncm-client-call client (car case) (lambda (result) (setq reply result)))
              (let ((deadline (+ (float-time) 15)))
                (while (and (null reply) (< (float-time) deadline))
                  (accept-process-output nil 0.05)))
              (should (eq (car-safe reply) :ok))
              (should (with-temp-buffer
                        (insert-file-contents log)
                        (string-match-p (regexp-quote (cadr case)) (buffer-string)))))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-theme-tokens-cover-both-palettes ()
  "Colours resolve per palette, and the UI defaults follow the mode."
  (should (equal (etaf-ncm-color :accent 'dark) "#EC4141"))
  (should-error (etaf-ncm-color :nonsense) :type 'etaf-ncm-error)
  ;; Every documented key must resolve in both palettes: the error banner
  ;; once used `:danger-bg' while the palette could not answer it.
  (dolist (key '(:bg :panel :panel2 :panel3 :line :ink :muted :dim
                     :accent :accent-fg :accent-soft :gold :ok :danger :danger-bg
                     :playing :selected :meter :cover))
    (dolist (mode '(dark light))
      (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\\'"
                              (etaf-ncm-color key mode)))))
  (let ((dark (etaf-ncm-color :bg 'dark))
        (dark-defaults (etaf-ncm-theme-defaults 'dark)))
    (should (plist-member dark-defaults :ui-accent))
    (should (equal (plist-get dark-defaults :ui-bg) dark))
    (should-not (equal dark (etaf-ncm-color :bg 'light)))
    (should (equal (etaf-ncm-color :bg 'dark) dark))
    (should-not (equal (etaf-ncm-theme-defaults 'light)
                       (etaf-ncm-theme-defaults 'dark)))))

(ert-deftest etaf-ncm-tests-mount-renders-and-revives ()
  "Mounting paints the library in a buffer and killing it releases the session."
  (let ((app (etaf-ncm-tests--session))
        (buffer (get-buffer-create " *etaf-ncm-tests-mount*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-ncm-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (with-current-buffer buffer
            (should (string-match-p "曲目 1" (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "每日推荐" (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p (plist-get (etaf-ncm-state app) :message)
                                    (buffer-substring-no-properties (point-min) (point-max)))))
          (kill-buffer buffer)
          (should-not (get-buffer " *etaf-ncm-tests-mount*"))
          (let ((again (get-buffer-create " *etaf-ncm-tests-mount*")))
            (etaf-mount again (etaf-ncm-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (with-current-buffer again
              (should (string-match-p "曲目 1" (buffer-substring-no-properties (point-min) (point-max)))))))
      (when (get-buffer " *etaf-ncm-tests-mount*")
        (kill-buffer " *etaf-ncm-tests-mount*")))))

(ert-deftest etaf-ncm-tests-open-and-close-own-a-buffer ()
  "Opening focuses the library list and closing kills the buffer."
  (let ((etaf-ncm-buffer-name " *etaf-ncm-tests-open*")
        (app (etaf-ncm-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-ncm-open app)))
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (should (eq (etaf-focused-host-ref (etaf-runtime-for-buffer buffer)) 'ncm-list))
            ;; The mode line stays: the buffer's name belongs in the session's
            ;; own chrome, and hiding it made the player feel like a separate
            ;; application.
            (should mode-line-format)
            (should (string-match-p "曲目 1" (buffer-substring-no-properties (point-min) (point-max)))))
          (etaf-ncm-close)
          (should-not (get-buffer etaf-ncm-buffer-name)))
      (when (get-buffer etaf-ncm-buffer-name)
        (kill-buffer etaf-ncm-buffer-name)))))

(ert-deftest etaf-ncm-tests-root-keys-own-the-canvas ()
  "The palette paints the canvas and `T' and `q' beat renderer bindings."
  (save-window-excursion
    (let* ((etaf-ncm-buffer-name " *etaf-ncm-tests-keys*")
           (etaf-ncm-theme-mode 'dark)
           (app (etaf-ncm-tests--session))
           (buffer (etaf-ncm-open app))
           (canvas (lambda ()
                     (with-current-buffer buffer
                       ;; The application owns the base remap; Ebox adds
                       ;; the root's own background as a relative remap.
                       (plist-get (car (last (alist-get 'default face-remapping-alist)))
                                  :background)))))
      (unwind-protect
          (with-current-buffer buffer
            (let ((before (funcall canvas)))
              (should (member before (list (etaf-ncm-color :bg 'dark)
                                           (etaf-ncm-color :bg 'light))))
              (execute-kbd-macro (kbd "T"))
              (should (equal (funcall canvas)
                             (if (equal before (etaf-ncm-color :bg 'dark))
                                 (etaf-ncm-color :bg 'light)
                               (etaf-ncm-color :bg 'dark)))))
            (execute-kbd-macro (kbd "q"))
            (should-not (buffer-live-p buffer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-ncm-tests-close-keeps-playing-and-quit-stops-it ()
  "Closing the window leaves playback; quitting the client stops it.
`q' only closes the client window, `Q' ends the client and must stop the
backend player before the buffer is gone."
  (setq etaf-ncm-tests--requests nil)
  (let ((etaf-ncm-buffer-name " *etaf-ncm-tests-quit*")
        (app (etaf-ncm-tests--session)))
    (unwind-protect
        (progn
          (etaf-ncm-open app)
          (etaf-ncm-close)
          (should-not (etaf-ncm-tests--request :stop))
          (etaf-ncm-open app)
          (etaf-ncm-quit)
          (should (etaf-ncm-tests--request :stop))
          (should-not (get-buffer etaf-ncm-buffer-name)))
      (when (get-buffer etaf-ncm-buffer-name)
        (kill-buffer etaf-ncm-buffer-name)))))

(ert-deftest etaf-ncm-tests-exiting-emacs-stops-only-the-player-it-started ()
  "Exiting Emacs stops a player the app started, and leaves other playback.
A play command records ownership; without one the exit hook must not touch
a player that the CLI or another client started."
  ;; Playback this app started is stopped on exit.
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-press-row app 2)
    (etaf-ncm-press-row app 2)
    (run-hooks 'kill-emacs-hook)
    (should (etaf-ncm-tests--request :stop)))
  ;; An app that never played must not stop someone else's playback.
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (run-hooks 'kill-emacs-hook)
    (should-not (etaf-ncm-tests--request :stop))))

(ert-deftest etaf-ncm-tests-open-fills-the-selected-window ()
  "Opening the player replaces the selected window instead of splitting it.
A native text app owns the whole window it was opened from; a general
display rule must not turn it into a playground-style pane."
  (let ((etaf-ncm-buffer-name " *etaf-ncm-tests-window*")
        (app (etaf-ncm-tests--session))
        (frame (selected-frame))
        (width (frame-width))
        (height (frame-height)))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (set-frame-size frame 120 40)
          (let ((windows (length (window-list)))
                (selected (selected-window)))
            (unwind-protect
                (progn
                  (etaf-ncm-open app)
                  (should (= (length (window-list)) windows))
                  (should (eq (selected-window) selected))
                  (should (eq (window-buffer selected)
                              (get-buffer etaf-ncm-buffer-name))))
              (etaf-ncm-close))))
      (set-frame-size frame width height)
      (when (get-buffer etaf-ncm-buffer-name)
        (kill-buffer etaf-ncm-buffer-name)))))

(ert-deftest etaf-ncm-tests-like-button-toggles-the-heart ()
  "A press on a liked heart removes the like; a second press adds it back."
  (let ((etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--status nil))
    (let ((app (etaf-ncm-tests--session)))
      (etaf-ncm-tests--with-player app
        (etaf-ncm-tests--rendered-text)
        ;; The fixture status plays song 1, which the liked-ids fixture lists.
        (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :liked) t))
        (etaf-ncm-tests--press-help "喜欢 / 取消喜欢 (f / F)")
        (should (etaf-ncm-tests--request :unlike))
        (should-not (plist-get (plist-get (etaf-ncm-state app) :status) :liked))
        (setq etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--press-help "喜欢 / 取消喜欢 (f / F)")
        (should (etaf-ncm-tests--request :like))
        (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :liked) t))))))

(ert-deftest etaf-ncm-tests-press-on-the-selected-row-plays-it ()
  "A press on the already selected row starts playback.
The gesture must not depend on a second press arriving inside a timing window:
publishing a selection can delay it past any fixed window."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 2)
    (should-not (etaf-ncm-tests--request :play))
    (etaf-ncm-press-row app 3)
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :daily)))
    (should (= (plist-get (etaf-ncm-tests--request :play) :start) 3))
    (should-not (etaf-ncm-tests--request :jump))))

(ert-deftest etaf-ncm-tests-press-selects-another-row-before-playing ()
  "A press on a different row selects it; the next press plays it."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-press-row app 4)
    (should (= (plist-get (etaf-ncm-state app) :selection) 3))
    (should-not (etaf-ncm-tests--request :play))
    (should (string-match-p "再点一次播放"
                            (or (plist-get (etaf-ncm-state app) :message) "")))
    (etaf-ncm-press-row app 4)
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :daily)))
    (should (= (plist-get (etaf-ncm-tests--request :play) :start) 4))
    (should-not (etaf-ncm-tests--request :jump))))

(ert-deftest etaf-ncm-tests-play-shows-the-picked-song-while-the-command-runs ()
  "A status poll answered during a slow play cannot move the track back.
The backend builds a queue before it switches, so a status command sent
while the play command is still running reports the previous song.  The
marker, the title and the queue count stay on the picked song until the
command settles; after that a fresh reply is the truth again."
  (setq etaf-ncm-tests--requests nil)
  (let* (play-reply
         (applied nil)
         (client (lambda (request callback)
                   (pcase (plist-get request :op)
                     (:play
                      (push request etaf-ncm-tests--requests)
                      (setq play-reply
                            (lambda (result)
                              (setq applied t)
                              (funcall callback result))))
                     (:status
                      (push request etaf-ncm-tests--requests)
                      (let ((status (etaf-ncm-tests--fixture "status")))
                        (when applied
                          (plist-put status :song_id "9")
                          (plist-put status :title "曲目 9")
                          (plist-put status :artist "歌手 9")
                          (plist-put status :queue_pos "9/30"))
                        (etaf-ncm-tests--reply callback status)))
                     (_ (etaf-ncm-tests--client request callback)))))
         (app (etaf-ncm-tests--session client))
         (reading (lambda () (etaf-ncm-state app))))
    (etaf-ncm-refresh app)
    ;; Double press row 4: the play command stays unanswered, like a backend
    ;; that is still resolving the stream URLs of the whole library.
    (etaf-ncm-press-row app 4)
    (etaf-ncm-press-row app 4)
    (let ((status (plist-get (funcall reading) :status)))
      (should (= 4 (plist-get status :song-id)))
      (should (equal "曲目 4" (plist-get status :title)))
      (should (equal "歌手 4" (plist-get status :artist)))
      (should (= 183 (plist-get status :duration)))
      (should (= 12 (plist-get status :queue-count))))
    ;; A poll sent while the backend still plays the previous song.
    (etaf-ncm-refresh app)
    (let ((status (plist-get (funcall reading) :status)))
      (should (= 4 (plist-get status :song-id)))
      (should (equal "曲目 4" (plist-get status :title)))
      (should (= 12 (plist-get status :queue-count))))
    ;; The command settles: its follow-up reply is the new truth.
    (funcall play-reply '(:ok (:ok t)))
    (let ((status (plist-get (funcall reading) :status)))
      (should (= 9 (plist-get status :song-id)))
      (should (equal "曲目 9" (plist-get status :title))))))

(ert-deftest etaf-ncm-tests-toggle-starts-the-selected-song-when-nothing-is-loaded ()
  "SPC with an empty queue plays the selected row instead of a no-op toggle."
  ;; Bind the scripted status: it is a global default for every other
  ;; scenario, so scribbling on it would change their backend too.
  (let ((etaf-ncm-tests--status
         (list :state "idle" :title "" :queue_pos "0/0" :volume "55")))
    (setq etaf-ncm-tests--requests nil)
    (let ((app (etaf-ncm-tests--session)))
      (etaf-ncm-refresh app)
      (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :state) 'idle))
      (etaf-ncm-toggle-playback app)
      (should (etaf-ncm-tests--request :play))
      (should-not (etaf-ncm-tests--request :toggle)))))

(ert-deftest etaf-ncm-tests-transport-effect-is-visible-before-the-reply ()
  "Pausing flips the displayed state before the backend answers."
  (setq etaf-ncm-tests--requests nil)
  (let* (app
         seen
         (client (lambda (request callback)
                   (when (eq (plist-get request :op) :toggle)
                     (push (plist-get (plist-get (etaf-ncm-state app) :status) :state)
                           seen))
                   (etaf-ncm-tests--client request callback))))
    (setq app (etaf-ncm-tests--session client))
    (etaf-ncm-refresh app)
    (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :state) 'playing))
    (etaf-ncm-toggle-playback app)
    (should (equal seen '(paused)))))

(ert-deftest etaf-ncm-tests-locate-shows-cached-rows-before-the-refresh ()
  "Revisiting a library shows its cached rows and refreshes in the background.
The background reply must not move the reader's selection."
  (setq etaf-ncm-tests--requests nil)
  (let* (app
         deferred
         defer-p
         (client (lambda (request callback)
                   (if defer-p
                       (push (cons request callback) deferred)
                     (etaf-ncm-tests--client request callback)))))
    (setq app (etaf-ncm-tests--session client))
    (etaf-ncm-refresh app)
    (etaf-ncm-locate app :playlists)
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 36))
    (setq defer-p t)
    (etaf-ncm-locate app :daily)
    (let ((state (etaf-ncm-state app)))
      (should (= (plist-get state :rows-total) 12))
      (should-not (plist-get state :loading))
      (should (equal (plist-get state :title) "每日推荐")))
    (etaf-ncm-move-selection app 4)
    (should-not deferred) ; Navigation does not launch a refresh process.
    (etaf-ncm-refresh app)
    (funcall (cdr (seq-find (lambda (entry) (eq (plist-get (car entry) :op) :browse)) deferred))
             (list :ok (etaf-ncm-tests--fixture "daily")))
    (should (= (plist-get (etaf-ncm-state app) :selection) 4))
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 12))))

(ert-deftest etaf-ncm-tests-library-snapshot-survives-restart ()
  "A new offline session restores populated and empty libraries before mounting."
  (let* ((directory (make-temp-file "ncm-snapshot-" t))
         (file (expand-file-name "library.eld" directory)) calls
         (client (lambda (request callback)
                   (if (eq (plist-get request :resource) :albums)
                       (funcall callback '(:ok (:albums nil :total 0)))
                     (etaf-ncm-tests--client request callback))))
         (app (etaf-ncm-create :client client :cache-file file)))
    (unwind-protect
        (progn
          (etaf-ncm-tests--with-player app
            (etaf-ncm-locate app :liked)
            (etaf-ncm-locate app :albums))
          (should (= #o600 (logand #o777 (file-modes file))))
          (let ((restored (etaf-ncm-create
                           :cache-file file :client (lambda (request _callback) (push request calls)))))
            (should (= 12 (plist-get (etaf-ncm-state restored) :rows-total)))
            (etaf-ncm-locate restored :liked)
            (should (> (plist-get (etaf-ncm-state restored) :rows-total) 0))
            (etaf-ncm-locate restored :albums)
            (should (= 0 (plist-get (etaf-ncm-state restored) :rows-total)))
            (should-not (plist-get (etaf-ncm-state restored) :loading))
            (should-not calls))
          (with-temp-file (expand-file-name "config.json" directory)
            (insert "{\"cookie\":\"fake-other-account\"}"))
          (let ((other (etaf-ncm-create :cache-file file
                                        :client (etaf-ncm-make-client :state-directory directory))))
            (should (= 0 (plist-get (etaf-ncm-state other) :rows-total)))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-snapshot-failure-is-a-cache-miss ()
  "Corrupt, oversized and incompatible snapshots never break startup."
  (let* ((directory (make-temp-file "ncm-bad-snapshot-" t))
         (file (expand-file-name "library.eld" directory)))
    (unwind-protect
        (progn
          (dolist (text '("(" "#.(error \"must not run\")" "(:schema 99 :entries nil)"))
            (with-temp-file file (insert text))
            (let ((app (etaf-ncm-create :client (lambda (_r _cb)) :cache-file file)))
              (should (= 0 (plist-get (etaf-ncm-state app) :rows-total)))))
          (with-temp-file file (insert (make-string (1+ (* 4 1024 1024)) ?x)))
          (let ((app (etaf-ncm-create :client (lambda (_r _cb)) :cache-file file)))
            (should (= 0 (plist-get (etaf-ncm-state app) :rows-total)))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-library-loads-are-deduplicated-and-isolated ()
  "Rapid navigation shares per-key work; late replies never replace another page."
  (let* (pending
         (app (etaf-ncm-create :client (lambda (r cb)
                                        (if (eq (plist-get r :op) :browse)
                                            (push (cons r cb) pending)
                                          (funcall cb '(:ok nil)))))))
    (etaf-ncm-locate app :daily)
    (etaf-ncm-locate app :liked)
    (etaf-ncm-locate app :daily)
    (should (= 2 (length pending)))
    (funcall (cdar pending) (list :ok (etaf-ncm-tests--fixture "daily")))
    (should (= 0 (plist-get (etaf-ncm-state app) :rows-total)))
    (funcall (cdr (cadr pending)) (list :ok (etaf-ncm-tests--fixture "daily")))
    (should (= 12 (plist-get (etaf-ncm-state app) :rows-total)))
    (let ((rows (plist-get (etaf-ncm-state app) :items)))
      (etaf-ncm-refresh app)
      (etaf-ncm-refresh app)
      (should (= 3 (length pending)))
      (funcall (cdar pending) '(:error "offline" :code "network"))
      (should (equal rows (plist-get (etaf-ncm-state app) :items)))
      (should-not (plist-get (etaf-ncm-state app) :error))
      (etaf-ncm-tests--with-player app nil)
      (funcall (cdar pending) '(:ok (:songs nil :total 0)))
      (should (equal rows (plist-get (etaf-ncm-state app) :items))))))

(ert-deftest etaf-ncm-tests-background-diff-preserves-identities ()
  "Equal replies skip row work; insertion preserves selected song and viewport."
  (let* ((songs (etaf-ncm-tests--songs 60)) deferred pending
         (app (etaf-ncm-create :client (lambda (r cb)
                                        (if (and deferred (eq (plist-get r :op) :browse))
                                            (setq pending cb)
                                          (funcall cb (if (eq (plist-get r :op) :browse)
                                                          (list :ok (list :songs songs :total (length songs)))
                                                        '(:ok nil))))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-move-selection app 20)
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (setq deferred t)
        (etaf-ncm-refresh app)
        (etaf-runtime-flush runtime)
        (let ((revision (etaf-runtime-revision runtime)))
          (funcall pending (list :ok (list :songs songs :total (length songs))))
          (etaf-runtime-flush runtime)
          (should (= revision (etaf-runtime-revision runtime))))
        (setq deferred nil)
        (setq songs (cons '(:id 99 :name "新歌" :artist "歌手" :ms 1000) songs))
        (etaf-ncm-refresh app)
        (should (= 21 (plist-get (etaf-ncm-state app) :selection)))
        (etaf-ncm-locate app :liked)
        (etaf-ncm-locate app :daily)
        (should (= 21 (plist-get (etaf-ncm-state app) :selection)))))))

;;; ---------------------------------------------------------------------------
;;; Long libraries and panel interaction
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-tests--songs (count &optional prefix)
  "Return COUNT backend songs with a distinct PREFIX."
  (cl-loop for index from 1 to count
           collect (list :id index :name (format "%s%03d" (or prefix "长列表") index)
                         :artist "歌手" :album "专辑" :ms 180000)))

(defun etaf-ncm-tests--rendered-text ()
  "Flush the current mounted player and read its text without properties."
  (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
  (buffer-substring-no-properties (point-min) (point-max)))

(defun etaf-ncm-tests--key (key)
  "Type KEY in the current player buffer through the command loop."
  (execute-kbd-macro (kbd key)))

(defun etaf-ncm-tests--wheel (window direction column row)
  "Send DIRECTION at COLUMN and ROW over WINDOW through the command loop.
The synthetic wheel event carries pixels, just like an Emacs mouse event."
  (execute-kbd-macro
   (vector (list direction
                 (list window (window-start window)
                       (cons (* column (window-font-width window))
                             (* row (window-font-height window))) 0)))))

(ert-deftest etaf-ncm-tests-browse-limit-covers-long-libraries ()
  "Browse loads 500 rows and respects the new limit, old limit and page floor."
  (dolist (limits '((1000 100 24 1000) (1000 1500 24 1500) (100 50 80 240)))
    (let* ((etaf-ncm-list-limit (nth 0 limits))
           (etaf-ncm-fetch-limit (nth 1 limits))
           (etaf-ncm-page-size (nth 2 limits))
           seen
           (app (etaf-ncm-create
                 :client (lambda (request callback)
                           (setq seen request)
                           (funcall callback
                                    (list :ok (list :total 500 :songs
                                                    (etaf-ncm-tests--songs
                                                     (min 500 (plist-get request :limit))))))))))
      (etaf-ncm-locate app :liked)
      (should (= (plist-get seen :limit) (nth 3 limits)))
      (should (= (plist-get (etaf-ncm-state app) :rows-total)
                 (min 500 (nth 3 limits))))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 500)))))

(ert-deftest etaf-ncm-tests-library-total-survives-cache-and-refresh ()
  "Partial totals survive cache hits, change without new rows, and survive errors."
  (let* ((songs (etaf-ncm-tests--songs 100))
         pending defer
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :browse)
                             (if defer
                                 (setq pending callback)
                               (funcall callback (list :ok (list :songs songs :total "500"))))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-locate app :liked)
      (should (= (plist-get (etaf-ncm-state app) :rows-total) 100))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 500))
      (should (string-match-p "已加载 100 / 共 500 首"
                              (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-locate app :daily)
      (setq defer t)
      (etaf-ncm-locate app :liked)
      (should-not (plist-get (etaf-ncm-state app) :loading))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 500))
      (etaf-ncm-move-selection app 99)
      (etaf-ncm-refresh app)
      (funcall pending (list :ok (list :songs songs :total 501)))
      (should (= (plist-get (etaf-ncm-state app) :selection) 99))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 501))
      (should (string-match-p "已加载 100 / 共 501 首"
                              (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-refresh app)
      (funcall pending (list :ok (list :songs nil :total 501)))
      (should (string-match-p "共 501 首"
                              (etaf-ncm-tests--rendered-text)))
      (should (string-match-p "已加载 0 / 共 501 首"
                              (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-refresh app)
      (funcall pending '(:error "加载失败"))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 501))
      (should (= (plist-get (etaf-ncm-state app) :rows-total) 0)))))

(ert-deftest etaf-ncm-tests-long-library-keys-show-one-based-ranges ()
  "Home, End and page keys navigate every loaded row and display one-based ranges."
  (let ((app (etaf-ncm-create
              :client (lambda (request callback)
                        (if (eq (plist-get request :op) :browse)
                            (funcall callback (list :ok (list :songs (etaf-ncm-tests--songs 500)
                                                             :total 500)))
                          (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (let ((size (plist-get (etaf-ncm-state app) :page-size)))
        (should (string-match-p "共 500 首" (etaf-ncm-tests--rendered-text)))
        (etaf-ncm-tests--key "<end>")
        (let ((state (etaf-ncm-state app)))
          (should (= (plist-get state :selection) 499))
          (should (= (plist-get (car (last (plist-get state :visible))) :id) 500)))
        (should (string-match-p "共 500 首"
                                (etaf-ncm-tests--rendered-text)))
        (etaf-ncm-tests--key "<prior>")
        (should (= (plist-get (etaf-ncm-state app) :selection) (- 499 size)))
        (etaf-ncm-tests--key "<next>")
        (should (= (plist-get (etaf-ncm-state app) :selection) 499))
        (etaf-ncm-tests--key "<home>")
        (should (= (plist-get (etaf-ncm-state app) :selection) 0))))))

(ert-deftest etaf-ncm-tests-narrow-layout-keeps-names ()
  "A narrow frame keeps each row's name and fills the page with loaded rows.
The compact row folds the artist into the name cell instead of letting the
name column collapse, so a playlist stays identifiable at phone widths, and
the page is not capped below the rows the window can show."
  (let* ((etaf-ncm-wide-columns 1000)
         (etaf-ncm-medium-columns 1000)
         (app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-locate app :playlists)
      (let ((text (etaf-ncm-tests--rendered-text))
            (state (etaf-ncm-state app)))
        (should (eq (plist-get state :layout) 'narrow))
        (should (string-match-p "歌单 1" text))
        (should (string-match-p "创建者 1" text))
        (should (> (plist-get state :page-size) 17))
        (should (= (length (plist-get state :visible))
                   (min etaf-ncm-render-limit (plist-get state :rows-total))))))))

(ert-deftest etaf-ncm-tests-superseded-library-keeps-visible-total ()
  "A late foreground reply cannot overwrite a revisited cached library or total."
  (let* (defer pending
         (app (etaf-ncm-create
               :client (lambda (_request callback)
                         (if defer
                             (push callback pending)
                           (funcall callback
                                    (list :ok (list :songs (etaf-ncm-tests--songs 100)
                                                    :total 500))))))))
    (etaf-ncm-locate app :liked)
    (setq defer t)
    (etaf-ncm-locate app :daily)
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 0))
    (should (= (plist-get (etaf-ncm-state app) :list-total) 0))
    (etaf-ncm-locate app :liked)
    (should (= 1 (length pending)))
    (funcall (car pending) (list :ok (list :songs (etaf-ncm-tests--songs 3) :total 3)))
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 100))
    (should (= (plist-get (etaf-ncm-state app) :list-total) 500))
    (should (eq (plist-get (etaf-ncm-state app) :section) :liked))))

(ert-deftest etaf-ncm-tests-song-row-starts-in-one-command ()
  "Each library plays the exact loaded ids, independent of later navigation."
  (dolist (section '(:daily :liked :fm))
    (let* ((etaf-ncm-page-size 8)
           (songs (etaf-ncm-tests--songs 200))
           requests play-reply
           (app (etaf-ncm-create
                 :client (lambda (request callback)
                           (push request requests)
                           (pcase (plist-get request :op)
                             (:browse (funcall callback (list :ok (list :songs songs))))
                             (:play (setq play-reply callback))
                             (:queue (funcall callback
                                              (list :ok (list :songs songs :count 200 :pos 137))))
                             (_ (etaf-ncm-tests--client request callback)))))))
      (etaf-ncm-locate app section)
      (etaf-ncm-press-row app 137)
      (should (= (plist-get (etaf-ncm-state app) :selection) 136))
      (setq requests nil)
      (etaf-ncm-press-row app 137)
      (should (equal requests (list (list :op :play :target (list :kind section)
                                          :ids (number-sequence 1 200) :start 137))))
      (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :song-id) 137))
      ;; Navigation while the request is in flight must not change its start.
      (etaf-ncm-move-selection app 10)
      (funcall play-reply '(:ok (:ok t)))
      (should-not (seq-find (lambda (request) (eq (plist-get request :op) :jump)) requests))
      (should (= (plist-get (plist-get (etaf-ncm-state app) :queue) :count) 200))
      (should (= (plist-get (plist-get (etaf-ncm-state app) :queue) :pos) 137))
      (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：长列表137")))))

(ert-deftest etaf-ncm-tests-song-row-failure-and-supersession ()
  "A failed or late play reply never sends a second playback command."
  (let* (pending jumps
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (pcase (plist-get request :op)
                           (:play (push callback pending))
                           (:jump (push request jumps)
                                  (funcall callback '(:error "跳转失败")))
                           (_ (etaf-ncm-tests--client request callback)))))))
    (etaf-ncm-locate app :daily)
    (etaf-ncm-activate-selection app)
    (funcall (pop pending) '(:error "播放失败"))
    (should-not jumps)
    (should (equal (plist-get (etaf-ncm-state app) :error) "播放失败"))
    (etaf-ncm-activate-selection app)
    (etaf-ncm-play app 999)
    (funcall (cadr pending) '(:ok (:ok t)))
    (should-not jumps)
    (funcall (car pending) '(:ok (:ok t)))
    (etaf-ncm-activate-selection app)
    (etaf-ncm-stop app)
    (funcall (car pending) '(:ok (:ok t)))
    (should-not jumps)
    (etaf-ncm-activate-selection app)
    (funcall (car pending) '(:ok (:ok t)))
    (should-not jumps)))

(ert-deftest etaf-ncm-tests-other-libraries-play-rows-directly ()
  "Recent, search and list-of-lists rows keep their individual play targets."
  (let ((app (etaf-ncm-tests--session)))
    (dolist (entry '((:recent :song) (:playlists :playlist) (:albums :album)
                     (:artists :artist) (:charts :chart) (:podcasts :podcast)
                     (:search :song)))
      (if (eq (car entry) :search)
          (etaf-ncm-search app "曲目")
        (etaf-ncm-locate app (car entry)))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-activate-selection app)
      (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                     (list :kind (cadr entry) :id (plist-get (car (etaf-ncm-tests--rows app)) :id))))
      (should-not (etaf-ncm-tests--request :jump)))))

(ert-deftest etaf-ncm-tests-play-all-only-for-supported-origins ()
  "Both header layouts offer play-all only for daily, liked and FM libraries."
  (dolist (wide '(1 1000))
    (let ((etaf-ncm-wide-columns wide)
          (app (etaf-ncm-tests--session)))
      (etaf-ncm-tests--with-player app
        (dolist (section '(:daily :liked :fm :playlists :albums :artists :charts
                           :podcasts :recent :search))
          (if (eq section :search)
              (etaf-ncm-search app "曲目")
            (etaf-ncm-locate app section))
          (let* ((at (string-match "播放全部" (etaf-ncm-tests--rendered-text)))
                 ;; Retained hidden Hosts keep text but mask it as native space
                 ;; and remove its keymap; it must not remain visibly actionable.
                 (visible (and at (not (eq (car-safe (get-text-property (1+ at) 'display)) 'space)))))
            (should (eq (and visible t) (and (memq section '(:daily :liked :fm)) t)))
            (when (and at (not visible)) (should-not (get-text-property (1+ at) 'keymap)))))))))

(ert-deftest etaf-ncm-tests-queue-wheel-scrolls-only-the-event-panel ()
  "Wheel events reach the entire queue, preserve selection and follow a new track."
  (dolist (layout '(wide medium narrow))
    (let* ((etaf-ncm-wide-columns (if (eq layout 'wide) 1 1000))
           (etaf-ncm-medium-columns (if (eq layout 'narrow) 1000 1))
           (songs (etaf-ncm-tests--songs 80 "队列"))
           (pos 40)
           (app (etaf-ncm-create
                 :client (lambda (request callback)
                           (if (eq (plist-get request :op) :queue)
                               (funcall callback (list :ok (list :count 90 :pos pos :songs songs)))
                             (etaf-ncm-tests--client request callback))))))
      (etaf-ncm-tests--with-player app
        (etaf-ncm-toggle-aside app)
        (should (eq (plist-get (etaf-ncm-state app) :layout) layout))
        (let* ((window (selected-window))
               (right (- (window-body-width window) 4)))
          (should (> (plist-get (etaf-ncm-state app) :queue-rows) 12))
          (should (string-match-p "共 90 首" (etaf-ncm-tests--rendered-text)))
          ;; The queue is one scrolling canvas, so a wheel moves it the way it
          ;; moves the library: the last entry comes into view and the first
          ;; one leaves.  Current buffer and point need not belong to the event
          ;; window.
          (with-temp-buffer
            (etaf-batch
              (dotimes (_ 100) (etaf-ncm-tests--wheel window 'wheel-down right 8))))
          (let ((text (etaf-ncm-tests--rendered-text)))
            (should (= (plist-get (etaf-ncm-state app) :selection) 0))
            (should (string-match-p "队列080" text)))
          (etaf-batch
            (dotimes (_ 100) (etaf-ncm-tests--wheel window 'wheel-up right 8)))
          (let ((text (etaf-ncm-tests--rendered-text)))
            (should (= (plist-get (etaf-ncm-state app) :selection) 0))
            (should (string-match-p "队列001" text)))
          (setq pos 60)
          (etaf-ncm-refresh app)
          (unless (eq layout 'wide) (etaf-ncm-show-pane app 'aside))
          (should (= (plist-get (etaf-ncm-state app) :selection) 0))
          ;; Outside the queue the wheel leaves the selection alone: the
          ;; library is one scrolling canvas, so its offset moves instead.
          (if (eq layout 'wide)
              (etaf-ncm-tests--wheel window 'wheel-down 2 8)
            (etaf-ncm-show-pane app 'list)
            (etaf-ncm-tests--wheel window 'wheel-down right 8))
          (should (= (plist-get (etaf-ncm-state app) :selection) 0))
          (etaf-ncm-toggle-aside app)
          (etaf-ncm-tests--wheel window 'wheel-down right 8)
          (should (= (plist-get (etaf-ncm-state app) :selection) 0)))))))

(ert-deftest etaf-ncm-tests-library-wheel-scrolls-the-canvas ()
  "Wheel over the library scrolls its canvas and leaves the selection alone."
  (let* ((songs (etaf-ncm-tests--songs 120 "曲目"))
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :browse)
                             (funcall callback (list :ok (list :songs songs :total 120)))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (let* ((window (selected-window))
             (runtime (etaf-runtime-for-buffer (current-buffer)))
             (column 40))
        (should (= 120 (plist-get (etaf-ncm-state app) :rows-total)))
        (should (string-match-p "共 120 首" (etaf-ncm-tests--rendered-text)))
        (should (= 0 (etaf-scroll-offset runtime 'ncm-list-scroll)))
        ;; One tick scrolls the canvas by the shared step.
        (etaf-ncm-tests--wheel window 'wheel-down column 8)
        (should (= etaf-ncm-wheel-rows
                   (etaf-scroll-offset runtime 'ncm-list-scroll)))
        (should (= (plist-get (etaf-ncm-state app) :selection) 0))
        ;; The canvas clamps at both ends and the whole list is reachable.
        (etaf-batch
          (dotimes (_ 200) (etaf-ncm-tests--wheel window 'wheel-down column 8)))
        (let ((offset (etaf-scroll-offset runtime 'ncm-list-scroll)))
          (should (and (> offset 0) (< offset 120))))
        (should (= (plist-get (etaf-ncm-state app) :selection) 0))
        (etaf-batch
          (dotimes (_ 200) (etaf-ncm-tests--wheel window 'wheel-up column 8)))
        (should (= 0 (etaf-scroll-offset runtime 'ncm-list-scroll)))
        ;; Arrowing still moves the selection and the canvas follows it.
        (etaf-ncm-move-selection app 60)
        (should (= (plist-get (etaf-ncm-state app) :selection) 60))))))

(ert-deftest etaf-ncm-tests-panel-budgets-fit-resized-windows ()
  "Queue and translated lyric windows shrink with their own panel height."
  (let* ((lyric (mapconcat (lambda (index) (format "[00:%02d.00]歌词%02d" index index))
                          (number-sequence 0 59) "\n"))
         (trans (replace-regexp-in-string "歌词" "译文" lyric))
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :lyric)
                             (funcall callback (list :ok (list :lyric lyric :trans trans)))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (let* ((before (etaf-ncm-state app))
             (text (etaf-ncm-tests--rendered-text))
             ;; The mode line takes a row, so the window holds one line fewer
             ;; and the centred lyric window starts a line later.  Read the
             ;; first line it shows instead of assuming the number.
             (first (and (string-match "歌词\\([0-9][0-9]\\)" text)
                         (match-string 1 text))))
        (should first)
        (should (string-match-p (format "歌词%s" first) text))
        (should (string-match-p (format "译文%s" first) text))
        (set-frame-height (selected-frame) 32)
        ;; Batch Emacs has no settle pass for the window-size bridge; drive
        ;; the settled viewport the framework would publish in a GUI.
        (etaf-refit)
        (etaf-ncm-refresh app)
        (let* ((after (etaf-ncm-state app))
               (text (etaf-ncm-tests--rendered-text))
               (count 0) (start 0))
          (should (< (plist-get after :queue-rows) (plist-get before :queue-rows)))
          (should (< (plist-get after :lyric-rows) (plist-get before :lyric-rows)))
          (let ((now (and (string-match "歌词\\([0-9][0-9]\\)" text)
                          (match-string 1 text))))
            (should now)
            (should (string-match-p (format "歌词%s" now) text))
            (should (string-match-p (format "译文%s" now) text)))
          (while (string-match "\\(?:歌词\\|译文\\)[0-9][0-9]" text start)
            (cl-incf count)
            (setq start (match-end 0)))
          (should (<= count (plist-get after :lyric-rows))))))))

(ert-deftest etaf-ncm-tests-queue-entries-click-and-tab-activate ()
  "Scrolled queue entries still jump on mouse activation and TAB/RET."
  (let* ((songs (etaf-ncm-tests--songs 45 "队列"))
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :queue)
                             (funcall callback (list :ok (list :songs songs :count 45 :pos 2)))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-toggle-aside app)
      (let* ((window (selected-window))
             (right (- (window-body-width window) 4)))
        ;; Every entry is published now, so the column itself is what carries
        ;; them; a click and RET on a row still reach the model.
        (etaf-ncm-tests--rendered-text)
        (goto-char (point-min))
        (search-forward-regexp "队列0\\([0-9][0-9]\\)")
        (should (match-string 1))
        (backward-char 1)
        (let* ((event (list 'mouse-1 (list window (point) (cons right 8) 0)))
               ;; Direct command invocation must supply the same input source
               ;; that Emacs binds while dispatching a native pointer event.
               (last-input-event event))
          (setq etaf-ncm-tests--requests nil)
          ;; A real click enters the command with the mouse event as
          ;; `last-input-event'; activation distinguishes it from RET.
          (let ((last-input-event event))
            (funcall (key-binding [mouse-1]) event))
          (should (plist-get (etaf-ncm-tests--request :jump) :index)))
        (etaf-ncm-tests--rendered-text)
        (let (index)
          (dotimes (_ 150)
            (unless index
              (call-interactively (key-binding (kbd "TAB")))
              (let ((help (get-char-property (point) 'help-echo)))
                (when (functionp help) (setq help (funcall help window (current-buffer) (point))))
                (when (and (stringp help)
                           (string-match "播放队列第 \\([0-9]+\\) 首" help))
                  (setq index (string-to-number (match-string 1 help)))))))
          (should index)
          ;; TAB walks the queue's cells; it only has to leave the first one to
          ;; prove the group is reachable at all.
          (should (> index 1))
          (setq etaf-ncm-tests--requests nil)
          (call-interactively (key-binding (kbd "RET")))
          (should (= (plist-get (etaf-ncm-tests--request :jump) :index) index))
          (should (= (plist-get (etaf-ncm-state app) :selection) 0)))))))


(defun etaf-ncm-tests--background (position)
  "Return POSITION's effective face background, honoring Ebox's face list."
  (let ((face (get-char-property position 'face)))
    (cond ((and (consp face) (keywordp (car face))) (plist-get face :background))
          ((listp face)
           (cl-loop for spec in face
                    when (and (consp spec) (plist-get spec :background))
                    return (plist-get spec :background))))))

(defun etaf-ncm-tests--sidebar-label-position (label)
  "Return the sidebar position of LABEL in the mounted player, or nil.
The sidebar's own items start at the line's left edge; the header repeats the
current library's name further right, so only the first twelve characters of a
line can hold a sidebar label."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (search-forward label nil t))
        (when (< (- (match-beginning 0) (line-beginning-position)) 12)
          (setq found (match-beginning 0))))
      found)))

(defun etaf-ncm-tests--sidebar-label-at (position)
  "Return the library label POSITION belongs to, or nil.
An unselected entry carries Ebox's hover handler as `help-echo' and keeps its
label in `ebox-help-echo'; the selected one keeps the plain label in
`help-echo' and has no run help, so either slot may hold it."
  (or (get-char-property position 'ebox-help-echo)
      (let ((help (get-char-property position 'help-echo)))
        (and (stringp help) help))))

(defun etaf-ncm-tests--sidebar-spacer-position (position)
  "Return the sidebar cell below its label at POSITION, or nil.
Stretch spaces occupy one character regardless of their display width, so
locate the cell by the node that owns it instead of by a character offset.
`help-echo' cannot identify it: an unselected entry carries Ebox's hover
handler there while the selected one keeps the plain label, and the list row
to the right carries the handler too."
  (save-excursion
    (goto-char position)
    (let ((owner (ebox--event-owner position))
          (found nil))
      (forward-line 1)
      (let ((end (line-end-position))
            (point (point)))
        (while (and (not found) (< point end))
          (when (eq (ebox--event-owner point) owner)
            (setq found point))
          (setq point (1+ point))))
      found)))

(ert-deftest etaf-ncm-tests-sidebar-selection-highlights-one-line ()
  "The selected library entry paints its text row, not its whole two-line cell."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((label (etaf-ncm-tests--sidebar-label-position "每日推荐")))
        (should label)
        (should (equal (etaf-ncm-tests--background label)
                       (etaf-ncm-color :accent-soft)))
        (let ((spacer (etaf-ncm-tests--sidebar-spacer-position label)))
          (should spacer)
          (should (= (char-after spacer) ?\s))
          (should-not (equal (etaf-ncm-tests--background spacer)
                             (etaf-ncm-color :accent-soft))))))))

(ert-deftest etaf-ncm-tests-sidebar-current-entry-keeps-its-surface-on-hover ()
  "The active library entry declares no hover surface over its own background."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((current (etaf-ncm-tests--sidebar-label-position "每日推荐"))
            (other (etaf-ncm-tests--sidebar-label-position "排行榜")))
        (should current)
        (should other)
        (should-not (get-text-property current 'mouse-face))
        (should (get-text-property other 'mouse-face))))))

(ert-deftest etaf-ncm-tests-sidebar-group-labels-leave-a-gap ()
  "A group label is separated from its first entry by a blank line."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((label-line (progn (goto-char (point-min))
                               (search-forward "我的音乐" nil t)
                               (line-number-at-pos)))
            (item-line (progn (goto-char (point-min))
                              (search-forward "我的歌单" nil t)
                              (line-number-at-pos))))
        (should label-line)
        (should item-line)
        (should (= 2 (- item-line label-line)))))))

(ert-deftest etaf-ncm-tests-viewport-width-uses-pixels ()
  "The first canvas already uses ETAF's display-safe pixel viewport."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
             (width (plist-get (etaf-ncm-state app) :viewport-width)))
        (should (= width (car (etaf-runtime-viewport runtime))))
        ;; A first input must not discover a different canvas and trigger a
        ;; whole-page resize after the player has already opened.
        (etaf-refit runtime (selected-window))
        (should (= width (car (etaf-runtime-viewport runtime))))
        (should (= width (plist-get (etaf-ncm-state app) :viewport-width)))))))

(ert-deftest etaf-ncm-tests-viewport-columns-follow-the-canvas-cell ()
  "The column budget divides by the cell the canvas draws with.
A canvas font, a text scale or a selected frame that is not the player's
leaves the frame's default face apart from that cell; budgeting with the frame
made the page draw narrower than the region it measured and left the right
side of a wide window empty."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (cl-letf (((symbol-function 'etaf-display-metrics)
                 (lambda (&optional _runtime)
                   (list :char-width 8 :line-height 16)))
                ((symbol-function 'frame-char-width)
                 (lambda (&optional _frame) 10)))
        ;; 800 pixels are 100 canvas cells, not the 80 the frame face gives.
        (should (= (etaf-ncm--viewport-columns 800 app) 100))))))


(ert-deftest etaf-ncm-tests-sidebar-entry-click-switches-library ()
  "Sidebar text and spacer clicks switch libraries, as does TAB/RET."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((label (etaf-ncm-tests--sidebar-label-position "私人 FM")))
        (should label)
        (goto-char label)
        (let* ((window (selected-window))
               (event (list 'mouse-1 (list window label '(1 . 1) 0)))
               (last-input-event event)
               (command (key-binding (vector event))))
          (should (commandp command))
          (let ((last-input-event event))
            (funcall command event))
          (etaf-ncm-tests--rendered-text)
          (should (eq (plist-get (etaf-ncm-state app) :section) :fm))))
      ;; Exercise the native press/release route on both lines of the cell.
      (dolist (target '(("每日推荐" :daily nil) ("私人 FM" :fm t)))
        (let ((position (etaf-ncm-tests--sidebar-label-position (car target))))
          (should position)
          (when (nth 2 target)
            (setq position (etaf-ncm-tests--sidebar-spacer-position position))
            (should position))
          (goto-char position)
          (let* ((window (selected-window))
                 (press (list 'down-mouse-1 (list window position '(1 . 1) 0)))
                 (release (list 'mouse-1 (list window position '(1 . 1) 1)))
                 (command (key-binding (vector press)))
                 (unread-command-events (list release)))
            (should (commandp command))
            (should (eq command (lookup-key (get-text-property position 'keymap)
                                           [down-mouse-1])))
            (let ((last-input-event press))
              (funcall command press))
            (etaf-ncm-tests--rendered-text)
            (should (eq (plist-get (etaf-ncm-state app) :section) (nth 1 target))))))
      ;; The sidebar is one Tab stop entered at the current library; arrows
      ;; then move between the libraries.
      (let ((labels (mapcar #'cadr (apply #'append (mapcar #'cdr etaf-ncm-sections))))
            found)
        (dotimes (_ 30)
          (unless found
            (execute-kbd-macro (kbd "TAB"))
            (setq found (member (etaf-ncm-tests--sidebar-label-at (point)) labels))))
        (should (equal (car found) "私人 FM"))
        (etaf-ncm-tests--key "<up>")
        (should (equal (etaf-ncm-tests--sidebar-label-at (point)) "每日推荐"))
        (execute-kbd-macro (kbd "RET"))
        (etaf-ncm-tests--rendered-text)
        (should (eq (plist-get (etaf-ncm-state app) :section) :daily))))))

(defun etaf-ncm-tests--host-pixels (host)
  "Return HOST's painted (LEFT WIDTH) through the public retained bounds."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (bounds (etaf-host-ref-bounds runtime host)))
    (should bounds)
    (let ((start (car bounds)) (end (cdr bounds)))
      (list (etaf-string-pixel-width
             (buffer-substring (save-excursion (goto-char start) (line-beginning-position)) start))
            (etaf-string-pixel-width (buffer-substring start end))))))

(defun etaf-ncm-tests--host-text (host)
  "Return HOST's painted text in the mounted player."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (bounds (etaf-host-ref-bounds runtime host)))
    (should bounds)
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(defun etaf-ncm-tests--slider-gesture (host phase ratio)
  "Dispatch a slider PHASE at RATIO of HOST's travel in the mounted player."
  (pcase-let* ((`(,left ,width) (etaf-ncm-tests--host-pixels host))
               (x (+ left (* ratio width))))
    (etaf-dispatch-event
     (etaf-runtime-for-buffer (current-buffer)) host 'drag
     (list :phase phase :host-ref host :window (selected-window)
           :buffer (current-buffer) :position (cons x 0)) t)))

(defun etaf-ncm-tests--press-help (help)
  "Activate the mounted control whose help text is HELP."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (entry (cl-find-if
                 (lambda (entry) (equal (plist-get (cdr entry) :help-echo) help))
                 (etaf-runtime-host-props-entries runtime))))
    (should entry)
    (etaf-dispatch-event runtime (car entry) 'press)))

(ert-deftest etaf-ncm-tests-player-volume-drag-and-reply ()
  "Click/drag sets the pointed volume optimistically and reconciles its reply."
  (let* ((etaf-ncm-tests--requests nil)
         pending handler
         (app (etaf-ncm-tests--session
               (lambda (request callback)
                 (if (eq (plist-get request :op) :volume)
                     (progn (push request etaf-ncm-tests--requests)
                            (setq pending callback))
                   (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (setq handler (plist-get (cdr (assq 'ncm-volume (etaf-runtime-host-props-entries (etaf-runtime-for-buffer (current-buffer))))) :on-drag))
      (dolist (sample '((0.5 50) (0.8 80) (-1 0) (2 100)))
        (setq etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--slider-gesture 'ncm-volume 'start 0.1)
        (etaf-ncm-tests--slider-gesture 'ncm-volume 'move (car sample))
        (should-not (etaf-ncm-tests--request :volume))
        (etaf-ncm-tests--slider-gesture 'ncm-volume 'end (car sample))
        (should (= (plist-get (etaf-ncm-tests--request :volume) :value) (cadr sample)))
        (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) (cadr sample)))
        (etaf-ncm-tests--rendered-text)
        (funcall pending '(:ok (:ok t)))
        (etaf-ncm-tests--rendered-text)
        (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) 55))
        (should (eq handler (plist-get (cdr (assq 'ncm-volume (etaf-runtime-host-props-entries (etaf-runtime-for-buffer (current-buffer))))) :on-drag))))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-tests--slider-gesture 'ncm-volume 'start 0.8)
      (etaf-ncm-tests--slider-gesture 'ncm-volume 'cancel 0.8)
      (should-not (etaf-ncm-tests--request :volume)))))

(ert-deftest etaf-ncm-tests-stale-status-keeps-the-pointed-volume ()
  "A status reply older than the volume command cannot move the number back.
The reply left the backend before the command; the follow-up status that the
reply triggers is the first one allowed to reconcile the value."
  (let* ((etaf-ncm-tests--requests nil)
         (etaf-ncm-tests--status nil)
         hold pending-status pending-volume
         (app (etaf-ncm-tests--session
              (lambda (request callback)
                (pcase (plist-get request :op)
                  (:status (if hold
                               (progn (push request etaf-ncm-tests--requests)
                                      (setq pending-status callback))
                             (etaf-ncm-tests--client request callback)))
                  (:volume (progn (push request etaf-ncm-tests--requests)
                                  (setq pending-volume callback)))
                  (_ (etaf-ncm-tests--client request callback)))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      ;; Hold the next status request in flight, then point the volume.
      (setq hold t)
      (etaf-ncm-refresh app)
      (etaf-ncm-set-volume app 80)
      (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) 80))
      ;; The old status arrives after the command: the number must stay put.
      (funcall pending-status (list :ok (etaf-ncm-tests--fixture "status")))
      (etaf-ncm-tests--rendered-text)
      (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) 80))
      ;; The command reply asks for fresh truth; the backend now reports 80.
      (setq hold nil
            etaf-ncm-tests--status
            (plist-put (etaf-ncm-tests--fixture "status") :volume "80"))
      (funcall pending-volume (list :ok (list :ok t)))
      (etaf-ncm-tests--rendered-text)
      (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) 80)))))

(ert-deftest etaf-ncm-tests-stale-status-keeps-the-pointed-position ()
  "A status reply older than a seek keeps the clicked position on the bar.
The clicked target is one second away from the reported one, which the seek
guard alone would accept as settled."
  (let* ((etaf-ncm-tests--requests nil)
         (etaf-ncm-tests--status nil)
         hold pending-status
         (app (etaf-ncm-tests--session
               (lambda (request callback)
                 (pcase (plist-get request :op)
                   (:status (if (and hold (not pending-status))
                                (progn (push request etaf-ncm-tests--requests)
                                       (setq pending-status callback))
                              (etaf-ncm-tests--client request callback)))
                   (_ (etaf-ncm-tests--client request callback)))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (setq hold t)
      (etaf-ncm-refresh app)
      ;; Point at about 42.8s of the 180s track: the relative seek rounds to
      ;; one second, so a guard built from the rounded offset would hold 43.8
      ;; instead of the pointed target.
      (etaf-ncm-tests--slider-gesture 'ncm-seek 'end (/ 42.8 180.0))
      (funcall pending-status (list :ok (etaf-ncm-tests--fixture "status")))
      (etaf-ncm-tests--rendered-text)
      (let ((elapsed (plist-get (plist-get (etaf-ncm-state app) :status) :elapsed)))
        (should (> elapsed 42.0))
        (should (< elapsed 43.4))))))

(ert-deftest etaf-ncm-tests-player-progress-range-seeks-by-pointer ()
  "The progress range follows status and seeks to the pointed position."
  (let* ((etaf-ncm-tests--status (etaf-ncm-tests--fixture "status"))
         (app (etaf-ncm-tests--session)))
    (setq etaf-ncm-tests--status (plist-put etaf-ncm-tests--status :duration "100"))
    (etaf-ncm-tests--with-player app
      (dolist (elapsed '(0 25 75 100))
        (setq etaf-ncm-tests--status (plist-put etaf-ncm-tests--status :elapsed elapsed))
        (etaf-ncm-refresh app)
        (etaf-ncm-tests--rendered-text)
        (should (etaf-host-ref-bounds (etaf-runtime-for-buffer (current-buffer))
                                      'ncm-seek)))
      (let ((etaf-ncm-tests--requests nil))
        (etaf-ncm-tests--slider-gesture 'ncm-seek 'end 0.5)
        (should (= (plist-get (etaf-ncm-tests--request :seek) :seconds) -50))))))

(ert-deftest etaf-ncm-tests-player-quality-and-compact-layouts ()
  "Only reported quality is badged; compact bars retain transport without it."
  (let* ((base (etaf-ncm-tests--fixture "status"))
         (etaf-ncm-tests--status base)
         (app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        ;; The badge keeps a fixed slot so a reported quality repaints the same
        ;; Host instead of rebuilding the bar; a missing quality must leave the
        ;; slot masked as native space rather than paint a stale badge.
        (let ((bounds (etaf-host-ref-bounds runtime 'ncm-quality)))
          (should bounds)
          (should (eq (car-safe (get-text-property (car bounds) 'display)) 'space)))
        (dolist (sample '(((:lossless t :vip t) "无损")
                          ((:quality "lossless") "无损")
                          ((:bitrate "320000") "320 kbps")
                          ((:vip_hint "VIP 专享") "VIP 专享")))
          (setq etaf-ncm-tests--status (append (car sample) base))
          (etaf-ncm-refresh app)
          (etaf-ncm-tests--rendered-text)
          (let ((bounds (etaf-host-ref-bounds runtime 'ncm-quality)))
            (should bounds)
            (should (string-match-p (regexp-quote (cadr sample))
                                    (buffer-substring-no-properties (car bounds) (cdr bounds))))))
        (dolist (sample '((90 medium) (64 narrow) (180 wide)))
          (set-frame-size (selected-frame) (car sample) 48)
          (etaf-refit)
          (etaf-ncm-refresh app)
          (etaf-ncm-tests--rendered-text)
          (should (eq (plist-get (etaf-ncm-state app) :layout) (cadr sample)))
          (should (etaf-host-ref-bounds runtime 'ncm-play))
          (should (etaf-host-ref-bounds runtime 'ncm-seek))
          (should (etaf-host-ref-bounds runtime 'ncm-volume))
          (should (eq (and (etaf-host-ref-bounds runtime 'ncm-cover) t)
                      (eq (cadr sample) 'wide)))
          (should (eq (and (etaf-host-ref-bounds runtime 'ncm-quality) t)
                      (eq (cadr sample) 'wide))))))))

(ert-deftest etaf-ncm-tests-now-page-geometry-keeps-a-square-cover ()
  "Both page designs keep the sharp cover square and the text column roomy."
  (dolist (mode '(auto immersive split))
    (dolist (sample '((200 50) (118 39) (80 24) (60 16)))
      (pcase-let* ((`(,columns ,rows) sample)
                   (wide (and (>= columns 96) (>= rows 22)))
                   (geometry (etaf-ncm-now-geometry columns rows 8 18 mode))
                   (art (* (plist-get geometry :art-columns) 8))
                   (art-rows (* (plist-get geometry :art-rows) 18))
                   (sections (etaf-ncm-now-sections
                              (plist-get geometry :panel-rows))))
        (should (eq (plist-get geometry :mode) mode))
        (should (eq (plist-get geometry :stacked) (not wide)))
        ;; `auto' splits a wide page and turns a narrow one into a poster.
        (when (eq mode 'auto)
          (should (eq (plist-get geometry :stacked) (not wide))))
        ;; The sharp copy stays square in pixels: a cell is wider than a row is
        ;; tall, so equal cell counts would stretch the artwork.
        (should (<= (abs (- art art-rows)) (* 2 18)))
        (should (>= (plist-get geometry :panel-columns) 16))
        (should (>= (plist-get geometry :content-columns) 16))
        (should (<= (plist-get geometry :content-columns)
                    (plist-get geometry :panel-columns)))
        ;; A stacked page keeps exactly the rows its parts need under the
        ;; poster: budgeting more left a dark band under the transport.
        (when (plist-get geometry :stacked)
          (should (>= (plist-get geometry :panel-rows)
                      (plist-get sections :rows)))
          (should (>= (plist-get geometry :panel-rows) 3)))
        (should (>= (plist-get sections :lyrics) 0))))))

(ert-deftest etaf-ncm-tests-now-page-sections-spend-the-panel ()
  "The parts appear as the window grows and never claim rows it lacks."
  (let ((previous-parts 0))
    (dolist (rows '(10 12 14 16 18 22 28 34 44 52))
      (let* ((sections (etaf-ncm-now-sections rows))
             (parts (+ (if (plist-get sections :header) 1 0)
                       (plist-get sections :title)
                       (if (plist-get sections :artist) 1 0)
                       (if (plist-get sections :progress) 2 0)
                       1
                       (if (plist-get sections :bars)
                           (1+ (plist-get sections :bars))
                         0)
                       (plist-get sections :lyrics))))
        ;; The block never asks for more rows than the window has.
        (should (<= (plist-get sections :rows) rows))
        ;; Its row count covers every part it shows.
        (should (<= parts (plist-get sections :rows)))
        ;; A taller window never shows fewer parts.
        (should (>= parts previous-parts))
        (setq previous-parts parts)))))

(ert-deftest etaf-ncm-tests-now-page-opens-from-every-layout ()
  "`o' opens the page in every layout, and a dismiss returns to the player."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (dolist (sample '((180 48) (90 30) (64 30) (46 20) (34 14)))
        (pcase-let ((`(,width ,height) sample))
          (set-frame-size (selected-frame) width height)
          (etaf-refit)
          (etaf-ncm-refresh app)
          (etaf-ncm-tests--rendered-text)
          (should (eq (plist-get (etaf-ncm-state app) :screen) 'library))
          (etaf-ncm-tests--key "o")
          (should (eq (plist-get (etaf-ncm-state app) :screen) 'now))
          (etaf-ncm-tests--rendered-text)
          (should (etaf-host-ref-bounds
                   (etaf-runtime-for-buffer (current-buffer)) 'ncm-now))
          (etaf-dispatch-event (etaf-runtime-for-buffer (current-buffer))
                               'ncm-now 'dismiss)
          (should (eq (plist-get (etaf-ncm-state app) :screen) 'library)))))))

(ert-deftest etaf-ncm-tests-now-page-shows-track-lyric-and-spectrum ()
  "The page carries the track, the lyric, the spectrum and the transport."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--key "o")
      (etaf-ncm-tests--rendered-text)
      (let ((runtime (etaf-runtime-for-buffer (current-buffer)))
            (text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "曲目 1" text))
        (should (string-match-p "第一行歌词" text))
        ;; The bars take rows only while there is a spectrum to draw in them, and
        ;; this player decodes no audio; the transport is what a page without
        ;; bars still draws.
        (should (etaf-host-ref-bounds runtime 'ncm-now-seek))
        (should (etaf-host-ref-bounds runtime 'ncm-now-seek))
        (should (etaf-host-ref-bounds runtime 'ncm-now-back))
        (should (plist-get (etaf-ncm-state app) :screen))))))

(ert-deftest etaf-ncm-tests-now-page-switches-its-design ()
  "`m' swaps the page design without leaving the page."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--key "o")
      (should (eq (plist-get (etaf-ncm-state app) :now-mode) 'auto))
      (etaf-ncm-tests--key "m")
      (should (memq (plist-get (etaf-ncm-state app) :now-mode)
                    '(immersive split)))
      (should (eq (plist-get (etaf-ncm-state app) :screen) 'now))
      (etaf-ncm-tests--rendered-text)
      (should (etaf-host-ref-bounds
               (etaf-runtime-for-buffer (current-buffer)) 'ncm-now))
      (etaf-ncm-tests--key "m")
      (should (memq (plist-get (etaf-ncm-state app) :now-mode)
                    '(immersive split))))))

(ert-deftest etaf-ncm-tests-spectrum-is-quiet-without-a-source ()
  "Without a playing source the meter reports silence and never stalls."
  (etaf-ncm-meter-stop)
  (should-not (etaf-ncm-meter-live-p))
  (should-not (etaf-ncm-meter-start nil 0))
  (should-not (etaf-ncm-meter-start "" 12))
  (should (equal (etaf-ncm-meter-levels 22) (make-list 22 0.0)))
  (should-not (etaf-ncm-meter-live-p)))

(ert-deftest etaf-ncm-tests-player-pane-buttons-preserve-state ()
  "Cover, lyric and queue controls reveal their pane without resetting selection."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-move-selection app 3)
      (etaf-ncm-tests--rendered-text)
      (let ((selected (plist-get (etaf-ncm-state app) :selection)))
        (should (= selected 3))
        (etaf-ncm-tests--press-help "显示播放列表")
        (should (eq (plist-get (etaf-ncm-state app) :aside) 'queue))
        ;; The cover opens the full-page view; Escape (a dismiss on the page
        ;; root) returns to the player without touching the open pane.
        (etaf-dispatch-event (etaf-runtime-for-buffer (current-buffer)) 'ncm-cover 'press)
        (should (eq (plist-get (etaf-ncm-state app) :screen) 'now))
        (should (eq (plist-get (etaf-ncm-state app) :aside) 'queue))
        (etaf-ncm-tests--rendered-text)
        (etaf-dispatch-event (etaf-runtime-for-buffer (current-buffer)) 'ncm-now 'dismiss)
        (should (eq (plist-get (etaf-ncm-state app) :screen) 'library))
        (set-frame-size (selected-frame) 64 48)
        (etaf-refit)
        (etaf-ncm-refresh app)
        (etaf-ncm-tests--rendered-text)
        (etaf-ncm-tests--press-help "显示播放列表")
        (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
        (etaf-ncm-tests--rendered-text)
        (etaf-ncm-tests--press-help "显示歌词 (i)")
        (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
        (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
        (dolist (label '("列表" "歌词" "队列"))
          (etaf-ncm-tests--press-help label)
          (etaf-ncm-tests--rendered-text)
          (let ((tabs (cl-remove-if-not
                       (lambda (entry) (member (plist-get (cdr entry) :help-echo)
                                                '("列表" "歌词" "队列")))
                       (etaf-runtime-host-props-entries
                        (etaf-runtime-for-buffer (current-buffer))))))
            (should (= (length tabs) 3))
            (dolist (tab tabs)
              (should (equal (plist-get (cdr tab) :width) '(ch 8)))
              (should (equal (plist-get (cdr tab) :height) '(lh 1))))
            (should (equal
                     (cl-loop for (_ . props) in tabs
                              when (equal (plist-get props :color) (etaf-ncm-color :accent))
                              collect (plist-get props :help-echo))
                     (list label)))))
        (should (equal (plist-get (etaf-ncm-state app) :selection) selected))))))

(ert-deftest etaf-ncm-tests-player-clock-moves-the-elapsed-label-and-meter ()
  "Playing seconds move the elapsed label and the progress meter in place.
The meter is the shared range's fill overlay, so its painted span grows
through a retained width update without publishing a new View."
  (let* ((etaf-ncm-tests--poll-interval 1)
         (calls 0)
         (app (etaf-ncm-tests--session
               (lambda (request callback)
                 (if (eq (plist-get request :op) :status)
                     (funcall callback
                              (list :ok (append (list :elapsed (number-to-string (+ 80 (* 10 (cl-incf calls)))))
                                                (etaf-ncm-tests--fixture "status"))))
                   (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
             (handler (plist-get (cdr (assq 'ncm-seek (etaf-runtime-host-props-entries runtime))) :on-drag))
             (before (etaf-ncm-tests--host-text 'ncm-elapsed))
             (meter-before (etaf-host-ref-bounds runtime 'ncm-meter)))
        (with-timeout (5 (ert-fail "Playback polling did not complete"))
          (while (< calls 3) (sleep-for 0.06)))
        (etaf-ncm-tests--rendered-text)
        (should (eq handler (plist-get (cdr (assq 'ncm-seek (etaf-runtime-host-props-entries runtime))) :on-drag)))
        (should-not (equal (etaf-ncm-tests--host-text 'ncm-elapsed) before))
        (let ((meter-after (etaf-host-ref-bounds runtime 'ncm-meter)))
          (should (and meter-before meter-after
                       (> (- (cdr meter-after) (car meter-after))
                          (- (cdr meter-before) (car meter-before))))))))))

(ert-deftest etaf-ncm-tests-keys-reach-the-player-around-the-renderer-map ()
  "The documented keys reach the player in a mounted buffer.
The renderer installs its own minor-mode map; the player's View keys take
precedence over it, so the real command loop finds the player command."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    ;; Read the backend status first: with a playing queue SPC toggles; the
    ;; empty-queue path plays the selection and has its own scenario.
    (etaf-ncm-refresh app)
    (etaf-ncm-tests--with-player app
      (execute-kbd-macro (kbd "<next>"))
      (let ((state (etaf-ncm-state app)))
        (should (= (plist-get state :selection)
                   (min (plist-get state :page-size)
                        (1- (plist-get state :rows-total))))))
      (execute-kbd-macro (kbd "<prior>"))
      (should (zerop (plist-get (etaf-ncm-state app) :selection)))
      (execute-kbd-macro (kbd "n"))
      (should (etaf-ncm-tests--request :next))
      (execute-kbd-macro (kbd "p"))
      (should (etaf-ncm-tests--request :previous))
      (execute-kbd-macro (kbd "SPC"))
      (should (etaf-ncm-tests--request :toggle))
      ;; The focused library list plays the selected row on RET.
      (execute-kbd-macro (kbd "<down>"))
      (setq etaf-ncm-tests--requests nil)
      (execute-kbd-macro (kbd "RET"))
      (should (or (etaf-ncm-tests--request :play)
                  (etaf-ncm-tests--request :jump))))))

;; ---------------------------------------------------------------------------
;; Keyboard regions
;; ---------------------------------------------------------------------------

(defun etaf-ncm-tests--palette (choice)
  "Open the ETAF palette, choose CHOICE when non-nil, return every label."
  (let (names)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (setq names (all-completions "" collection))
                 (or (and choice (seq-find (lambda (name) (string-prefix-p choice name)) names))
                     (keyboard-quit)))))
      (condition-case nil (etaf-palette) (quit nil)))
    names))

(ert-deftest etaf-ncm-tests-embedded-letters-and-layered-return ()
  "An embedded player's letters and help stay inside the entered host layer."
  (let* ((app (etaf-ncm-tests--session))
         (buffer (generate-new-buffer " *ncm-embedded-keys*"))
         (etaf-ncm-tests--requests nil)
         (exits 0) (host-actions 0))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column :keys (list (list "a" (lambda () (cl-incf host-actions)) "Host action"))
              (box :ref 'ncm-test-shell :tab-index 0 "Host")
              (box :key-scope 'local :region '(:id ncm-test-content :label "Music")
                   :on-dismiss (lambda () (cl-incf exits)
                                 (etaf-focus (etaf-runtime-for-buffer buffer) 'ncm-test-shell))
                (expr (etaf-ncm-view app)))))
           '(:viewport-width 1300 :viewport-height 48))
          (let ((runtime (etaf-runtime-for-buffer buffer)))
            (etaf-runtime-refit runtime 1300 48)
            (etaf-focus runtime 'ncm-list)
            (with-current-buffer buffer
              (call-interactively (key-binding (kbd "a") t))
              (should (etaf-ncm-tests--request :add))
              (should (= host-actions 0))
              (let ((before (etaf-ncm-state app)))
                (etaf-help runtime)
                (call-interactively (key-binding (kbd "a") t))
                (should (= host-actions 0))
                (should (= 1 (etaf-ncm-tests--request-count :add)))
                (call-interactively (key-binding (kbd "<escape>") t))
                (should (= exits 0))
                (should (eq (etaf-focused-host-ref runtime) 'ncm-list))
                (call-interactively (key-binding (kbd "<escape>") t))
                (should (= exits 1))
                (should (eq (etaf-focused-host-ref runtime) 'ncm-test-shell))
                (setq etaf-ncm-tests--requests nil)
                (call-interactively (key-binding (kbd "a") t))
                (should (= host-actions 1))
                (should-not etaf-ncm-tests--requests)
                (etaf-region-focus 'ncm-test-content runtime)
                (should (eq (etaf-focused-host-ref runtime) 'ncm-list))
                (let* ((after (etaf-ncm-state app))
                       (selection (plist-get after :selection))
                       (status (plist-get after :status)))
                  (should (equal selection (plist-get before :selection)))
                  (should (equal status (plist-get before :status))))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(ert-deftest etaf-ncm-tests-help-is-modal-read-only-and-restores-selection ()
  "Question mark shows real keys in place without changing playback or selection."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
             (buffer (current-buffer))
             (windows (window-list)) (buffers (buffer-list))
             (before (etaf-ncm-state app)))
        (etaf-focus runtime 'ncm-list)
        (etaf-ncm-tests--key "?")
        (let* ((data (etaf-help-data runtime))
               (title (plist-get data :title))
               (entries (mapcan (lambda (group) (copy-sequence (plist-get group :entries)))
                                (plist-get data :groups)))
               (alias (cl-find "=" entries :key (lambda (entry) (plist-get entry :key))
                               :test #'equal)))
          (should (equal title "网易云音乐"))
          (should alias))
        (should (equal windows (window-list)))
        (should (equal buffers (buffer-list)))
        (should (eq buffer (window-buffer)))
        (setq etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--key "n p a f <down>")
        (should-not etaf-ncm-tests--requests)
        (etaf-ncm-tests--key "/ n ? <escape>")
        (let ((editing (etaf-text-input-active-p runtime))
              (text (buffer-substring-no-properties (point-min) (point-max))))
          (should-not editing)
          (should (string-match-p "快捷键" text)))
        (etaf-ncm-tests--key "<escape>")
        (let* ((after (etaf-ncm-state app))
               (selection (plist-get after :selection))
               (status (plist-get after :status))
               (focus (etaf-focused-host-ref runtime))
               (closed (etaf-help-close runtime)))
          (should (equal selection (plist-get before :selection)))
          (should (equal status (plist-get before :status)))
          (should (eq focus 'ncm-list))
          (should-not closed))))))

(ert-deftest etaf-ncm-tests-palette-lists-and-runs-the-player-keys ()
  "The explicit ETAF palette lists and executes player keys and controls."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-tests--with-player app
      (let ((names (etaf-ncm-tests--palette nil)))
        (dolist (label '("下一首" "播放选中行" "切换歌词 / 队列" "音乐库：每日推荐" "音量，点击或拖动调节"))
          (should (seq-find (lambda (name) (string-prefix-p label name)) names))))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-tests--palette "下一首")
      (should (etaf-ncm-tests--request :next)))))

(ert-deftest etaf-ncm-tests-list-arrows-move-the-selection-and-tab-leaves ()
  "The focused list moves its selection with arrows; Tab moves to the next region."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (should (eq (etaf-focused-host-ref runtime) 'ncm-list))
        (etaf-ncm-tests--key "<down>")
        (etaf-ncm-tests--key "C-n")
        (should (= (plist-get (etaf-ncm-state app) :selection) 2))
        (etaf-ncm-tests--key "<up>")
        (should (= (plist-get (etaf-ncm-state app) :selection) 1))
        ;; The cursor follows the selection bar while the list holds focus;
        ;; the bar slides to the row, so wait for it to land there.
        (etaf-ncm-tests--rendered-text)
        (should (etaf-ncm-tests--wait
                 (lambda ()
                   (string-match-p "曲目 2"
                                   (buffer-substring-no-properties
                                    (line-beginning-position) (line-end-position))))))
        (etaf-ncm-tests--key "TAB")
        (should-not (eq (etaf-focused-host-ref runtime) 'ncm-list))
        (etaf-ncm-tests--key "<backtab>")
        (should (eq (etaf-focused-host-ref runtime) 'ncm-list))
        ;; Outside the list the arrows move focus, not the selection.
        (etaf-ncm-tests--key "TAB")
        (etaf-ncm-tests--key "<down>")
        (should (= (plist-get (etaf-ncm-state app) :selection) 1))))))

(ert-deftest etaf-ncm-tests-volume-and-seek-step-from-the-keyboard ()
  "Focused volume and progress ranges step by five with Left and Right."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-tests--with-player app
      (let ((runtime (etaf-runtime-for-buffer (current-buffer)))
            (volume (plist-get (plist-get (etaf-ncm-state app) :status) :volume)))
        (etaf-focus runtime 'ncm-volume)
        (setq etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--key "<right>")
        (should (= (plist-get (etaf-ncm-tests--request :volume) :value)
                   (min 100 (+ (or volume 0) 5))))))))

(ert-deftest etaf-ncm-tests-compact-pane-switch-moves-focus-into-the-pane ()
  "Showing the aside in a compact layout moves focus off the hidden list."
  (let* ((etaf-ncm-wide-columns 1000)
         (etaf-ncm-medium-columns 1000)
         (app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (should (eq (plist-get (etaf-ncm-state app) :layout) 'narrow))
        (should (eq (etaf-focused-host-ref runtime) 'ncm-list))
        (etaf-ncm-tests--key "v")
        (etaf-ncm-tests--rendered-text)
        (let ((focus (etaf-focused-host-ref runtime)))
          (should focus)
          (should-not (eq focus 'ncm-list)))
        (etaf-ncm-tests--key "v")
        (etaf-ncm-tests--rendered-text)
        (should (eq (etaf-focused-host-ref runtime) 'ncm-list))))))

(defun etaf-ncm-tests--wait (predicate &optional timeout)
  "Wait until PREDICATE is non-nil for at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall predicate)))

(defun etaf-ncm-tests--request-count (op &optional resource)
  "Return how many recorded requests used OP, optionally for RESOURCE."
  (cl-count-if (lambda (request)
                 (and (eq (plist-get request :op) op)
                      (or (null resource)
                          (eq (plist-get request :resource) resource))))
               etaf-ncm-tests--requests))

(ert-deftest etaf-ncm-tests-refresh-pauses-while-hidden ()
  "A player no window shows pauses its background library refresh."
  (setq etaf-ncm-tests--requests nil)
  (let* ((etaf-ncm-status-interval 0.05)
         (etaf-ncm-library-refresh-interval 0.05)
         (app (etaf-ncm-tests--session)))
    (unwind-protect
        (let* ((buffer (etaf-ncm-open app))
               (other (get-buffer-create " *etaf-ncm-tests-other*")))
          (etaf-ncm-refresh app)
          (should (etaf-ncm-tests--wait
                   (lambda () (> (etaf-ncm-tests--request-count :browse :fm) 0))))
          ;; 藏起来：后台刷新停下（等一拍再比快照，避免把在途请求算进来）。
          (set-window-buffer (get-buffer-window buffer t) other)
          (accept-process-output nil 0.2)
          (let ((before (etaf-ncm-tests--request-count :browse)))
            (accept-process-output nil 0.5)
            (should (= before (etaf-ncm-tests--request-count :browse)))
            ;; 重新显示：刷新恢复。
            (set-window-buffer (get-buffer-window other t) buffer)
            (should (etaf-ncm-tests--wait
                     (lambda () (> (etaf-ncm-tests--request-count :browse) before))))))
      (etaf-ncm-close))))

(ert-deftest etaf-ncm-tests-library-failure-pauses-refresh ()
  "A library refresh that needs a human pauses the warmer until a load succeeds."
  (setq etaf-ncm-tests--requests nil)
  ;; The warmer refreshes one stale list per tick and warms an uncached one
  ;; only while every cached list is fresh, so the freshness interval must
  ;; span several ticks for the FM list to be reached.
  (let* ((etaf-ncm-status-interval 0.05)
         (etaf-ncm-library-refresh-interval 0.3)
         (fail-auth t)
         (app nil)
         (client (lambda (request callback)
                   ;; 失败分支自己记账：脚本客户端只会记成功的请求。
                   (if (and fail-auth
                            (eq (plist-get request :op) :browse)
                            (eq (plist-get request :resource) :fm))
                       (progn
                         (push request etaf-ncm-tests--requests)
                         (funcall callback
                                  (list :error "登录已过期"
                                        :hint "netease-music.sh login"
                                        :code "auth")))
                     (etaf-ncm-tests--client request callback)))))
    (setq app (etaf-ncm-tests--session client))
    (unwind-protect
        (progn
          (etaf-ncm-open app)
          (etaf-ncm-refresh app)
          (should (etaf-ncm-tests--wait
                   (lambda () (> (etaf-ncm-tests--request-count :browse :fm) 0))))
          ;; 暂停后不再有任何后台刷新（快照比较，不清理账目）。
          (accept-process-output nil 0.2)
          (let ((before (etaf-ncm-tests--request-count :browse)))
            (accept-process-output nil 0.5)
            (should (= before (etaf-ncm-tests--request-count :browse))))
          ;; 前台加载成功解除暂停：刷新恢复。
          (let ((before (etaf-ncm-tests--request-count :browse :fm)))
            (setq fail-auth nil)
            (etaf-ncm-locate app :charts)
            (should (etaf-ncm-tests--wait
                     (lambda ()
                       (> (etaf-ncm-tests--request-count :browse :fm) before))))))
      (etaf-ncm-close))))

(ert-deftest etaf-ncm-tests-refresh-marks-downloaded-rows ()
  "Refreshing folds the backend download registry into the visible rows."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app))))
    (should (= (length (plist-get state :downloads)) 1))
    (should (plist-get (nth 0 (plist-get state :items)) :downloaded))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :download-level) "lossless"))
    (should-not (plist-get (nth 1 (plist-get state :items)) :downloaded))))

(ert-deftest etaf-ncm-tests-download-requests-the-row-and-marks-it ()
  "Downloading a row asks the backend by id, then marks the row and the state."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app)))
         (row (nth 1 (plist-get state :items))))
    (should-not (plist-get row :downloaded))
    (etaf-ncm-download app row)
    (let ((request (etaf-ncm-tests--request :download)))
      (should request)
      (should (= (plist-get request :id) 2))
      (should-not (plist-get request :force)))
    (should (plist-get (nth 1 (plist-get (etaf-ncm-state app) :items)) :downloaded))
    (should (= (length (plist-get (etaf-ncm-state app) :downloads)) 2))
    (should (string-match-p "已下载" (plist-get (etaf-ncm-state app) :message)))))

(ert-deftest etaf-ncm-tests-download-refreshes-an-existing-file ()
  "A second download of the same song asks the backend to refresh the file."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app)))
         (row (nth 0 (plist-get state :items))))
    (should (plist-get row :downloaded))
    (setq etaf-ncm-tests--requests nil)
    (etaf-ncm-download app row)
    (should (plist-get (etaf-ncm-tests--request :download) :force))))

(ert-deftest etaf-ncm-tests-row-action-dispatches-by-key ()
  "Inline row actions dispatch without opening a menu or playing the row."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (setq etaf-ncm-tests--requests nil)
    (etaf-ncm-row-action app 1 'download)
    (should (= (plist-get (etaf-ncm-tests--request :download) :id) 1))
    (setq etaf-ncm-tests--requests nil)
    (etaf-ncm-row-action app 1 'queue)
    (should (= (plist-get (etaf-ncm-tests--request :add) :id) 1))
    (setq etaf-ncm-tests--requests nil)
    (etaf-ncm-row-action app 1 'play)
    (should (eq (plist-get (etaf-ncm-tests--request :play) :op) :play))
    (should-error (etaf-ncm-row-action app 999 'play) :type 'etaf-ncm-error)
    (should-error (etaf-ncm-row-action app 1 'bogus) :type 'etaf-ncm-error)
    (etaf-ncm-tests--with-player app
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-tests--press-help "下载到本地（勾号表示已下载，点击可重新下载）")
      (should (etaf-ncm-tests--request :download))
      (should-not (etaf-ncm-tests--request :play))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-tests--press-help "加入队列")
      (should (etaf-ncm-tests--request :add))
      (should-not (etaf-ncm-tests--request :play)))))

(ert-deftest etaf-ncm-tests-download-key-uses-the-selection ()
  "The d key downloads the row the library selection points at."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 1)
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--key "d"))
    (should (= (plist-get (etaf-ncm-tests--request :download) :id) 2))))

(ert-deftest etaf-ncm-tests-download-reply-survives-a-track-switch ()
  "A download reply landing after a song change still registers the file."
  (setq etaf-ncm-tests--requests nil)
  (let* ((download-callback nil)
         (client (lambda (request callback)
                   (if (eq (plist-get request :op) :download)
                       (progn (push request etaf-ncm-tests--requests)
                              (setq download-callback callback))
                     (etaf-ncm-tests--client request callback))))
         (app (etaf-ncm-tests--session client)))
    (unwind-protect
        (progn
          (etaf-ncm-refresh app)
          (let ((row (nth 1 (plist-get (etaf-ncm-state app) :items))))
            (should-not (plist-get row :downloaded))
            (etaf-ncm-download app row)
            (should download-callback)
            ;; The reader switches off the download while its reply is in flight.
            (setq etaf-ncm-tests--status
                  (let ((status (copy-sequence (etaf-ncm-tests--fixture "status"))))
                    (plist-put status :song_id "3")
                    (plist-put status :title "曲目 3")
                    status))
            (etaf-ncm-next-track app)
            (should (equal "曲目 3" (plist-get (plist-get (etaf-ncm-state app) :status) :title)))
            ;; The late reply is keyed by song id, not by the current song or row.
            (funcall download-callback
                     (list :ok (list :id 2 :name "曲目 2" :artist "歌手"
                                     :file "/tmp/曲目 2.flac" :level "lossless"
                                     :br 1000 :bytes 10 :at "2026-10-05T20:00:00+0800")))
            (let ((after (etaf-ncm-state app)))
              (should (plist-get (nth 1 (plist-get after :items)) :downloaded))
              (should (= 2 (length (plist-get after :downloads))))
              (should (string-match-p "已下载" (plist-get after :message))))))
      (setq etaf-ncm-tests--status nil))))

(ert-deftest etaf-ncm-tests-lyric-cache-serves-a-restart ()
  "A persisted lyric answers the next session without a backend request."
  (let* ((directory (make-temp-file "ncm-media-cache" t))
         (cache-file (expand-file-name "library-cache.eld" directory)))
    (unwind-protect
        (progn
          (setq etaf-ncm-tests--requests nil)
          (let ((app (etaf-ncm-create :client #'etaf-ncm-tests--client
                                      :cache-file cache-file)))
            (etaf-ncm-refresh app)
            (should (= 1 (cl-count-if (lambda (entry)
                                        (eq (plist-get entry :op) :lyric))
                                      etaf-ncm-tests--requests)))
            (should (equal "第五行歌词" (plist-get (etaf-ncm-state app) :lyric-line)))
            (should (file-readable-p (expand-file-name "media-cache.sqlite" directory))))
          ;; A fresh session with the same snapshot must not ask for the lyric.
          (setq etaf-ncm-tests--requests nil)
          (let* ((lyric-asked nil)
                 (client (lambda (request callback)
                           (if (eq (plist-get request :op) :lyric)
                               (progn (setq lyric-asked t)
                                      (funcall callback (list :error "offline")))
                             (etaf-ncm-tests--client request callback))))
                 (app (etaf-ncm-create :client client :cache-file cache-file)))
            (etaf-ncm-refresh app)
            (should-not lyric-asked)
            (should (equal 1 (plist-get (plist-get (etaf-ncm-state app) :lyric) :id)))
            (should (equal "第五行歌词" (plist-get (etaf-ncm-state app) :lyric-line)))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-child-environment-always-has-a-utf8-locale ()
  "The backend child runs with a UTF-8 locale even when the parent has none.
The backend prints and parses Chinese text, so a missing or non-UTF-8 locale
breaks it; a stub backend records the environment it was spawned with."
  (skip-unless etaf-ncm-tests--shell-entry-p)
  (let* ((directory (make-temp-file "etaf-ncm-locale" t))
         (scripts (expand-file-name "scripts" directory))
         (script (expand-file-name "netease-music.sh" scripts))
         (log (expand-file-name "env.log" directory))
         reply)
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file script
            (insert "#!/bin/sh\n"
                    (format "env > %s\n" (shell-quote-argument log))
                    "printf '{\"ok\": true}\\n'\n"))
          (set-file-modes script #o755)
          (let ((process-environment '("PATH=/usr/bin" "LC_ALL=en_US.ISO8859-1"))
                (client (etaf-ncm-make-client :backend-directory directory
                                              :state-directory directory
                                              :timeout 10))
                (deadline (+ (float-time) 10)))
            (etaf-ncm-client-call client (list :op :downloads)
                                  (lambda (result) (setq reply result)))
            (while (and (null reply) (< (float-time) deadline))
              (accept-process-output nil 0.05))
            (should (eq (car-safe reply) :ok))
            (let ((environment (with-temp-buffer
                                 (insert-file-contents log)
                                 (buffer-string))))
              (should (string-match-p "LC_CTYPE=.*UTF-8" environment))
              (should-not (string-match-p "^LC_ALL=" environment)))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-only-the-playing-row-shows-the-play-marker ()
  "Non-playing rows keep their numbers; the playing row shows the marker.
A reactive computed object is truthy on its own, and a closure over a
`cl-loop' variable would read the last row for every row, so either mistake
makes the whole list look as if every song were playing."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-refresh app)
      (let ((text (etaf-ncm-tests--rendered-text)))
        (should (string-match-p "▶ +曲目 1" text))
        (should (string-match-p "3  曲目 3" text))
        (should (string-match-p "4  曲目 4" text))))))

(defconst etaf-ncm-tests--cover-png
  (concat "iVBORw0KGgoAAAANSUhEUgAAABAAAAAoCAIAAAB4uO32AAAEkUlEQVR4nA3LEdMCMACA4SgKdlH0"
          "3SCKRlGwi6LuhSgaRcEuirpBFI2iYBdF3SCKRlGwi6JuEEX7Cd8efzqdDqKD7KA66A50MB1sB9fB"
          "dwgdYofUIXcoHWqHTqeL6CK7qC66C11MF9vFdfFdQpfYJXXJXUqX2m2hh+ghe6geugc9TA/bw/Xw"
          "PUKP2CP1yD1Kj9proY/oI/uoProPfUwf28f18X1Cn9gn9cl9Sp/ab2GAGCAHqAF6AAPMADvADfAD"
          "woA4IA3IA8qAOmjhD/GH/EP9of/gD/OH/cP94f8If8Q/0h/5j/JH/WthiBgih6gheghDzBA7xA3x"
          "Q8KQOCQNyUPKkDpsYYQYIUeoEXoEI8wIO8KN8CPCiDgijcgjyog6akEhFFKhFFqBwiiswim8Iiii"
          "IimyoiiqamGMGCPHqDF6DGPMGDvGjfFjwpg4Jo3JY8qYOm5hgpggJ6gJegITzAQ7wU3wE8KEOCFN"
          "yBPKhDppYYqYIqeoKXoKU8wUO8VN8VPClDglTclTypQ6bWGGmCFnqBl6BjPMDDvDzfAzwow4I83I"
          "M8qMOmthjpgj56g5eg5zzBw7x83xc8KcOCfNyXPKnDpvYYFYIBeoBXoBC8wCu8At8AvCgrggLcgL"
          "yoK6aGGJWCKXqCV6CUvMErvELfFLwpK4JC3JS8qSumzBIAzSoAzagMEYrMEZvCEYoiEZsqEYqmlh"
          "hVghV6gVegUrzAq7wq3wK8KKuCKtyCvKirpqYY1YI9eoNXoNa8wau8at8WvCmrgmrclrypq6bmGD"
          "2CA3qA16AxvMBrvBbfAbwoa4IW3IG8qGumlhi9git6gtegtbzBa7xW3xW8KWuCVtyVvKlrptYYfY"
          "IXeoHXoHO8wOu8Pt8DvCjrgj7cg7yo66a2GP2CP3qD16D3vMHrvH7fF7wp64J+3Je8qeum/hgDgg"
          "D6gD+gAHzAF7wB3wB8KBeCAdyAfKgXpowSM80qM82oPHeKzHebwneKInebKneKpv4Yg4Io+oI/oI"
          "R8wRe8Qd8UfCkXgkHclHypF6bOGEOCFPqBP6BCfMCXvCnfAnwol4Ip3IJ8qJemrhjDgjz6gz+gxn"
          "zBl7xp3xZ8KZeCadyWfKmXpu4YK4IC+oC/oCF8wFe8Fd8BfChXghXcgXyoV6aeGKuCKvqCv6ClfM"
          "FXvFXfFXwpV4JV3JV8qVem3hhrghb6gb+gY3zA17w93wN8KNeCPdyDfKjXpr4Y64I++oO/oOd8wd"
          "e8fd8XfCnXgn3cl3yp16byEhEjKhEjpBwiRswiV8IiRiIiVyoiRqauGBeCAfqAf6AQ/MA/vAPfAP"
          "woP4ID3ID8qD+mjhiXgin6gn+glPzBP7xD3xT8KT+CQ9yU/Kk/ps4YV4IV+oF/oFL8wL+8K98C/C"
          "i/givcgvyov6auGNeCPfqDf6DW/MG/vGvfFvwpv4Jr3Jb8qb+m7hg/ggP6gP+gMfzAf7wX3wH8KH"
          "+CF9yB/Kh/pp4Yv4Ir+oL/oLX8wX+8V98V/Cl/glfclfypf6beGH+CF/qB/6Bz/MD/vD/fA/wo/4"
          "I/3IP8qP+uMfR7YYrqg8tOcAAAAASUVORK5CYII=")
  "A 16x40 PNG used to verify cover scaling, centering and slicing.")

(defun etaf-ncm-tests--write-cover (file)
  "Write the test cover PNG to FILE."
  (with-temp-file file
    (set-buffer-multibyte nil)
    (insert (base64-decode-string etaf-ncm-tests--cover-png))))

(defun etaf-ncm-tests--stub-cover-backend (directory)
  "Create a stub netease-music backend in DIRECTORY; return its script path.
The script records its arguments, materializes the requested cover download,
and answers with the documented JSON shapes.  A queue.json in the same
directory drives the queue track list."
  (let ((scripts (expand-file-name "scripts" directory))
        (log (expand-file-name "calls.log" directory)))
    (make-directory scripts t)
    (with-temp-file (expand-file-name "netease-music.sh" scripts)
      (insert "#!/bin/sh\n"
              (format "printf '%%s\\n' \"$*\" >> %s\n" (shell-quote-argument log))
              "case \"$1\" in\n"
              "  cover)\n"
              "    prev=\"\"\n"
              "    for arg in \"$@\"; do\n"
              "      if [ \"$prev\" = \"--download\" ]; then target=\"$arg\"; fi\n"
              "      prev=\"$arg\"\n"
              "    done\n"
              "    : > \"$target\"\n"
              "    printf '{\"id\":%s,\"cover\":\"https://example.invalid/a.jpg\",\"file\":\"%s\",\"bytes\":0}\\n' \"$2\" \"$target\"\n"
              "    ;;\n"
              "  *) printf '{\"ok\":true}\\n' ;;\n"
              "esac\n"))
    (set-file-modes (expand-file-name "netease-music.sh" scripts) #o755)
    ;; Signing in, playback and cover downloads run through the Node entry on
    ;; every system, so the stub needs it too; the shell entry still serves the
    ;; requests that remain there.
    (with-temp-file (expand-file-name "netease-cli.mjs" scripts)
      ;; A .mjs file is an ES module, so the stub imports instead of requiring.
      (insert "#!/usr/bin/env node\n"
              "import fs from 'node:fs';\n"
              "const args = process.argv.slice(2);\n"
              (format "fs.appendFileSync(%S, args.join(' ') + '\\n');\n" log)
              "if (args[0] === 'cover') {\n"
              "  const id = Number(args[1]);\n"
              "  const target = args[args.indexOf('--download') + 1];\n"
              "  fs.writeFileSync(target, '');\n"
              "  process.stdout.write(JSON.stringify({id: id,"
              " cover: 'https://example.invalid/a.jpg', file: target, bytes: 0}) + '\\n');\n"
              "} else {\n"
              "  process.stdout.write(JSON.stringify({ok: true}) + '\\n');\n"
              "}\n"))
    (set-file-modes (expand-file-name "netease-cli.mjs" scripts) #o755)
    (expand-file-name "netease-music.sh" scripts)))

(ert-deftest etaf-ncm-tests-cover-request-downloads-through-the-backend-entry ()
  "The cover request records the backend command and reports the saved file."
  (skip-unless etaf-ncm-tests--shell-entry-p)
  (let* ((directory (make-temp-file "ncm-cover-backend" t))
         (target (expand-file-name "art.img" directory))
         reply)
    (unwind-protect
        (progn
          (etaf-ncm-tests--stub-cover-backend directory)
          (let* ((client (etaf-ncm-make-client :backend-directory directory :timeout 10))
                 (deadline (+ (float-time) 10)))
            (etaf-ncm-client-call client (list :op :cover :id 7 :file target)
                                  (lambda (result) (setq reply result)))
            (while (and (null reply) (< (float-time) deadline))
              (accept-process-output nil 0.05))
            (should (eq (car-safe reply) :ok))
            (should (equal 7 (plist-get (cadr reply) :id)))
            (should (equal target (plist-get (cadr reply) :file)))
            (should (file-readable-p target))
            (should (with-temp-buffer
                      (insert-file-contents (expand-file-name "calls.log" directory))
                      (string-match-p
                       (regexp-quote (format "cover 7 --download %s --force" target))
                       (buffer-string))))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-queue-tracks-keep-the-cover-url ()
  "Queue tracks normalized from the backend state carry the cover URL."
  (skip-unless etaf-ncm-tests--shell-entry-p)
  (let* ((directory (make-temp-file "ncm-cover-queue" t))
         reply)
    (unwind-protect
        (progn
          (etaf-ncm-tests--stub-cover-backend directory)
          (let* ((client (etaf-ncm-make-client :backend-directory directory
                                               :state-directory directory
                                               :timeout 10))
                 (ask (lambda ()
                        (setq reply nil)
                        (let ((deadline (+ (float-time) 10)))
                          (etaf-ncm-client-call client (list :op :queue :limit 5)
                                                (lambda (result) (setq reply result)))
                          (while (and (null reply) (< (float-time) deadline))
                            (accept-process-output nil 0.05)))
                        reply)))
            (with-temp-file (expand-file-name "queue.json" directory)
              (insert "{\"songs\":[{\"id\":1,\"name\":\"曲目\",\"artist\":\"歌手\","
                      "\"album\":\"专辑\",\"ms\":1000,\"vip\":false,"
                      "\"cover\":\"https://example.invalid/a.jpg\"}]}"))
            (let ((result (funcall ask)))
              (should (eq (car-safe result) :ok))
              (should (equal "https://example.invalid/a.jpg"
                             (plist-get (car (plist-get (cadr result) :songs)) :cover))))
            (with-temp-file (expand-file-name "queue.json" directory)
              (insert "{\"songs\":[{\"id\":1,\"name\":\"曲目\"}]}"))
            (should (equal "" (plist-get (car (plist-get (cadr (funcall ask)) :songs)) :cover)))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-cover-follows-status-before-queue-replies ()
  "Playback truth selects artwork even when queue replies arrive out of order."
  (let* ((directory (make-temp-file "ncm-cover-order" t))
         (etaf-ncm-state-directory directory)
         status-reply queue-reply covers
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (pcase (plist-get request :op)
                           (:status (setq status-reply callback))
                           (:queue (setq queue-reply callback))
                           (:cover (push (plist-get request :id) covers))
                           (_ (funcall callback '(:ok nil))))))))
    (unwind-protect
        (progn
          (etaf-ncm-refresh app)
          ;; The queue's position can still describe the previous track.
          (funcall queue-reply
                   '(:ok (:count 2 :pos 1
                          :songs ((:id 1 :cover "https://example.invalid/1.png")
                                  (:id 2 :cover "https://example.invalid/2.png")))))
          (should (equal (car covers) 1))
          (funcall status-reply '(:ok (:song_id 2 :state "playing" :queue_pos "1/2")))
          (should (equal (car covers) 2))
          ;; A later switch starts its artwork without waiting for another queue.
          (etaf-ncm-next-track app)
          (funcall status-reply '(:ok (:song_id 1 :state "playing" :queue_pos "1/2")))
          (should (equal (car covers) 1))
          ;; An obsolete queue must not select an unrelated cover by position.
          (funcall queue-reply
                   '(:ok (:count 1 :pos 1
                          :songs ((:id 9 :cover "https://example.invalid/9.png")))))
          (should (equal (car covers) 1)))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-mounted-cover-follows-consecutive-track-changes ()
  "Both displayed covers follow same-size artwork changes without reopening."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (let* ((directory (make-temp-file "ncm-cover-switch" t))
         (etaf-ncm-state-directory directory)
         (etaf-ncm-buffer-name (generate-new-buffer-name " *ncm-cover-switch*"))
         (etaf-ncm-status-interval 3600)
         (etaf-ncm-prefetch-libraries nil)
         (images (mapcar #'base64-decode-string
                         '("iVBORw0KGgoAAAANSUhEUgAAABAAAAAoCAIAAAB4uO32AAAAIElEQVR4nGN44ehIEmIY1TCqYVTDqIZRDaMaRjXQSwMA6D6JLshYpFUAAAAASUVORK5CYII="
                           "iVBORw0KGgoAAAANSUhEUgAAABAAAAAoCAIAAAB4uO32AAAAIElEQVR4nGPQyLtDEmIY1TCqYVTDqIZRDaMaRjXQSwMAGRSdLqowPiEAAAAASUVORK5CYII=")))
         (songs '((:id 1 :name "Red cover" :artist "Artist" :cover "https://example.invalid/red.png")
                  (:id 2 :name "Blue cover" :artist "Artist" :cover "https://example.invalid/blue.png")))
         (playing 1)
         (app (etaf-ncm-create
               :client
               (lambda (request callback)
                 (funcall
                  callback
                  (list
                   :ok
                   (pcase (plist-get request :op)
                     (:next (setq playing (if (= playing 1) 2 1)) nil)
                     (:status (list :song_id playing :state "playing"
                                    :title (plist-get (nth (1- playing) songs) :name)
                                    :queue_pos (format "%d/2" playing)))
                     (:browse (list :songs songs))
                     (:queue (list :count 2 :pos playing :songs songs))
                     (:cover
                      (let ((file (plist-get request :file)))
                        (with-temp-file file
                          (set-buffer-multibyte nil)
                          (insert (nth (1- (plist-get request :id)) images)))
                        (list :file file)))
                     (_ nil)))))))
         buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (etaf-ncm-open app))
          (etaf-ncm-show-pane app 'aside)
          (dotimes (step 4)
            (when (> step 0) (etaf-ncm-next-track app))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (= playing (plist-get (plist-get (etaf-ncm-state app) :status)
                                         :song-id)))
            (with-current-buffer buffer
              (let ((position (point-min)) (found nil))
                (while (< position (point-max))
                  (let* ((display (get-text-property position 'display))
                         (image (cond ((imagep display) display)
                                      ((listp display) (car (last display))))))
                    (when (and (imagep image)
                               (eq (plist-get (cdr image) :type) 'png))
                      (setq found t)
                      (ert-info ((format "Track change %d, song %d" step playing))
                        (should (equal (secure-hash 'sha256 (nth (1- playing) images))
                                       (secure-hash 'sha256
                                                    (plist-get (cdr image) :data)))))))
                  (setq position (next-single-property-change
                                  position 'display nil (point-max))))
                (should found)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (etaf-ncm-close)))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-playing-song-cover-is-downloaded-to-the-state-directory ()
  "Refreshing downloads the playing song's cover into the local cache once."
  (setq etaf-ncm-tests--requests nil)
  (let* ((state-dir (make-temp-file "ncm-cover-state" t))
         (client (lambda (request callback)
                   (pcase (plist-get request :op)
                     (:cover
                      (push request etaf-ncm-tests--requests)
                      (etaf-ncm-tests--write-cover (plist-get request :file))
                      (funcall callback
                               (list :ok (list :id (plist-get request :id)
                                               :file (plist-get request :file)))))
                     (_
                      (etaf-ncm-tests--client
                       request
                       (lambda (reply)
                         (when (and (eq (plist-get request :op) :queue)
                                    (eq (car reply) :ok))
                           (let ((songs (plist-get (cadr reply) :songs)))
                             (when songs
                               (plist-put (car songs) :cover
                                          "https://example.invalid/a.jpg"))))
                         (funcall callback reply)))))))
         (etaf-ncm-state-directory state-dir)
         (app (etaf-ncm-tests--session client)))
    (unwind-protect
        (progn
          (etaf-ncm-refresh app)
          (let ((request (etaf-ncm-tests--request :cover)))
            (should request)
            (should (equal 1 (plist-get request :id)))
            (should (equal (expand-file-name "covers/1" state-dir)
                           (plist-get request :file)))
            (should (file-readable-p (plist-get request :file))))
          (should (equal (expand-file-name "covers/1" state-dir)
                         (etaf-value (plist-get app :cover-file))))
          ;; The same song is not requested twice by later refreshes.
          (etaf-ncm-refresh app)
          (should (= 1 (cl-count-if (lambda (entry) (eq (plist-get entry :op) :cover))
                                    etaf-ncm-tests--requests))))
      (delete-directory state-dir t))))

(ert-deftest etaf-ncm-tests-cover-clears-when-the-playing-song-has-none ()
  "Moving to a song without a cover clears the previous art immediately."
  (setq etaf-ncm-tests--requests nil)
  (let* ((state-dir (make-temp-file "ncm-cover-state" t))
         (second-song nil)
         (client (lambda (request callback)
                   (pcase (plist-get request :op)
                     (:cover
                      (push request etaf-ncm-tests--requests)
                      (etaf-ncm-tests--write-cover (plist-get request :file))
                      (funcall callback
                               (list :ok (list :id (plist-get request :id)
                                               :file (plist-get request :file)))))
                     (_
                      (etaf-ncm-tests--client
                       request
                       (lambda (reply)
                         (when (and (eq (plist-get request :op) :queue)
                                    (eq (car reply) :ok))
                           (if second-song
                               (progn
                                 (plist-put (cadr reply) :songs
                                            (list (list :id 9 :name "曲目 9")))
                                 (plist-put (cadr reply) :pos 1))
                             (let ((songs (plist-get (cadr reply) :songs)))
                               (when songs
                                 (plist-put (car songs) :cover
                                            "https://example.invalid/a.jpg")))))
                         (funcall callback reply)))))))
         (etaf-ncm-state-directory state-dir)
         (app (etaf-ncm-tests--session client)))
    (unwind-protect
        (progn
          (etaf-ncm-refresh app)
          (should (etaf-value (plist-get app :cover-file)))
          (setq second-song t)
          (setq etaf-ncm-tests--status
                (let ((status (copy-sequence (etaf-ncm-tests--fixture "status"))))
                  (plist-put status :song_id "9")))
          (etaf-ncm-refresh app)
          (should-not (etaf-value (plist-get app :cover-file)))
          (should (= 1 (cl-count-if (lambda (entry) (eq (plist-get entry :op) :cover))
                                    etaf-ncm-tests--requests))))
      (setq etaf-ncm-tests--status nil)
      (delete-directory state-dir t))))

(ert-deftest etaf-ncm-tests-cover-index-serves-the-next-session ()
  "The media cache keeps a cover per URL and reuses it across sessions."
  (setq etaf-ncm-tests--requests nil)
  (let* ((state-dir (make-temp-file "ncm-cover-state" t))
         (cache-dir (make-temp-file "ncm-cover-cache" t))
         (cache-file (expand-file-name "library-cache.eld" cache-dir))
         (url "https://example.invalid/a.jpg")
         (make-client (lambda (cover-url)
                        (lambda (request callback)
                          (if (eq (plist-get request :op) :cover)
                              (progn
                                (push request etaf-ncm-tests--requests)
                                (etaf-ncm-tests--write-cover (plist-get request :file))
                                (funcall callback
                                         (list :ok (list :id (plist-get request :id)
                                                         :file (plist-get request :file)))))
                            (etaf-ncm-tests--client
                             request
                             (lambda (reply)
                               (when (and (eq (plist-get request :op) :queue)
                                          (eq (car reply) :ok))
                                 (let ((songs (plist-get (cadr reply) :songs)))
                                   (when songs (plist-put (car songs) :cover cover-url))))
                               (funcall callback reply)))))))
         (etaf-ncm-state-directory state-dir)
         (cover-requests
          (lambda ()
            (cl-count-if (lambda (entry) (eq (plist-get entry :op) :cover))
                         etaf-ncm-tests--requests))))
    (unwind-protect
        (let ((file (expand-file-name "covers/1" state-dir)))
          ;; The first session downloads the cover and indexes it.
          (let ((app (etaf-ncm-create :client (funcall make-client url)
                                      :cache-file cache-file)))
            (etaf-ncm-refresh app)
            (should (= 1 (funcall cover-requests)))
            (should (equal file (etaf-value (plist-get app :cover-file)))))
          ;; A fresh session with the same URL reuses the indexed file.
          (setq etaf-ncm-tests--requests nil)
          (let ((app (etaf-ncm-create :client (funcall make-client url)
                                      :cache-file cache-file)))
            (etaf-ncm-refresh app)
            (should (= 0 (funcall cover-requests)))
            (should (equal file (etaf-value (plist-get app :cover-file)))))
          ;; A changed URL invalidates the entry and downloads again.
          (setq etaf-ncm-tests--requests nil)
          (let ((app (etaf-ncm-create
                      :client (funcall make-client "https://example.invalid/b.jpg")
                      :cache-file cache-file)))
            (etaf-ncm-refresh app)
            (should (= 1 (funcall cover-requests)))
            (should (equal file (etaf-value (plist-get app :cover-file))))))
      (setq etaf-ncm-tests--status nil)
      (delete-directory state-dir t)
      (delete-directory cache-dir t))))

(ert-deftest etaf-ncm-tests-selection-bar-slides-across-rows ()
  "A selection move animates the overlay bar through the rows it crosses."
  ;; Slow the shared animation clock: a loaded runner can otherwise advance
  ;; past the intermediate frames this test samples.
  (let ((app (etaf-ncm-tests--session))
        (etaf-animation-speed 0.1))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
             (start-line (line-number-at-pos
                          (car (etaf-host-ref-bounds runtime 'ncm-list-selection))))
             (target-line (+ start-line 3)))
        (etaf-ncm-move-selection app 3)
        ;; The bar leaves the start row and, before landing, occupies a row
        ;; between the two; a snap would never show the middle row.
        (should (etaf-ncm-tests--wait
                 (lambda ()
                   (let ((line (line-number-at-pos
                                (car (etaf-host-ref-bounds
                                      runtime 'ncm-list-selection)))))
                     (and (/= line start-line) (/= line target-line))))))
        (should (etaf-ncm-tests--wait
                 (lambda ()
                   (= (line-number-at-pos
                       (car (etaf-host-ref-bounds runtime 'ncm-list-selection)))
                      target-line))))))))

(ert-deftest etaf-ncm-tests-small-frames-use-the-card-family ()
  "A frame too small for its chrome keeps only what it is read for.
A card keeps the cover band, one pane and the transport; a tile drops the
cover, the progress line and the switch row, and gives every remaining row to
the lyric.  Neither draws the header, the chip strip or the player bar."
  (dolist (sample '((46 18 card) (34 14 tile)))
    (let ((app (etaf-ncm-tests--session)))
      (etaf-ncm-tests--with-player app
        (etaf-ncm-refresh app)
        (set-frame-size (selected-frame) (car sample) (cadr sample))
        (etaf-refit)
        (etaf-ncm-refresh app)
        (let* ((layout (plist-get (etaf-ncm-state app) :layout))
               (text (etaf-ncm-tests--rendered-text)))
          (should (eq layout (caddr sample)))
          (should (> (plist-get (etaf-ncm-state app) :page-size) 0))
          ;; The mode line takes a row, so the lyric window starts one line
          ;; later; any of the song's lines proves the pane is showing words.
          (should (string-match-p "行歌词" text))
          (should-not (string-match-p "搜索歌曲" text))
          (should-not (string-match-p "播放全部" text))
          (if (eq layout 'card)
              (progn
                (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
                (should (string-match-p "专辑" text))
                (should (string-match-p "歌词" text))
                (should (string-match-p "03:00" text))
                (etaf-ncm-show-pane app 'list)
                (should (string-match-p "曲目 1" (etaf-ncm-tests--rendered-text))))
            ;; A tile spends no row on a progress line or a switch row.
            (should-not (string-match-p "03:00" text))
            (should-not (string-match-p "列表" text))
            (should (string-match-p "曲目 1 - 歌手 1" text))))))))

(ert-deftest etaf-ncm-tests-card-tabs-open-a-library ()
  "A card switches libraries from its strip instead of naming a generic list.
The two library tabs load 收藏 and 推荐 into the same pane, the lyric tab
brings the panel back, and the queue keeps `i' as its way in at that size."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-refresh app)
      (set-frame-size (selected-frame) 46 18)
      (etaf-refit)
      (etaf-ncm-refresh app)
      (let ((text (etaf-ncm-tests--rendered-text)))
        (should (string-match-p "收藏" text))
        (should (string-match-p "歌词" text))
        (should (string-match-p "推荐" text))
        (should-not (string-match-p "列表" text))
        (should-not (string-match-p "队列" text)))
      (etaf-ncm-tests--press-help "推荐")
      (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))
      (should (eq (plist-get (etaf-ncm-state app) :section) :daily))
      (etaf-ncm-tests--press-help "收藏")
      (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))
      (should (eq (plist-get (etaf-ncm-state app) :section) :liked))
      (should (string-match-p "曲目 1" (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-tests--press-help "歌词")
      (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
      (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
      (execute-kbd-macro (kbd "i"))
      (should (eq (plist-get (etaf-ncm-state app) :aside) 'queue)))))

(defvar etaf-ncm-tests--surface-model nil
  "Player session mounted by the surface host during a case.")

(etaf-define-component etaf-ncm-tests-surface-host (&key surface)
  "Provide SURFACE to the player mounted below."
  :setup (etaf-surface-provide surface)
  :view (expr (etaf-ncm-view etaf-ncm-tests--surface-model)))

(ert-deftest etaf-ncm-tests-declares-its-palette-to-a-host ()
  "A panel frames the player with the player's own palette and switch.
The declared mode cell is the same one `T' writes, so the host's switch and
the player's own switch are one appearance state."
  (let ((surface (etaf-surface-create))
        (buffer (generate-new-buffer " *etaf-ncm-tests-surface*")))
    (let ((etaf-ncm-tests--surface-model (etaf-ncm-tests--session)))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-ncm-tests-surface-host :surface surface))
                        (list :viewport-width 1200 :viewport-height 40))
            (should (equal '((light . "亮") (auto . "随") (dark . "暗"))
                           (etaf-surface-modes surface)))
            (should (equal (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg)
                           (etaf-ncm-color
                            :bg (etaf-value (etaf-surface-mode surface)))))
            ;; The host's switch writes the cell the player paints from.
            (etaf-set-value (etaf-surface-mode surface) 'light)
            (should (equal (plist-get (etaf-value (etaf-surface-theme surface))
                                      :ui-bg)
                           (etaf-ncm-color :bg 'light))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (etaf-set-value (etaf-surface-mode surface) 'auto)))))

(ert-deftest etaf-ncm-tests-reload-action-names-what-it-can-do ()
  "The header reload reads 刷新 on a fixed library and 换一批 on private FM.
A daily reload returns the same rows, so the action must not promise a new
batch there; private FM answers with new songs, so it keeps the word."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-refresh app)
      (let ((text (etaf-ncm-tests--rendered-text)))
        (should (string-match-p "刷新" text))
        (should-not (string-match-p "换一批" text)))
      (etaf-ncm-locate app :fm)
      (let ((text (etaf-ncm-tests--rendered-text)))
        (should (string-match-p "换一批" text))
        (should-not (string-match-p "刷新" text))))))

(provide 'etaf-ncm-tests)

;;; etaf-ncm-tests.el ends here
