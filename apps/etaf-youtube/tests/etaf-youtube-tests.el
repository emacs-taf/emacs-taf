;;; etaf-youtube-tests.el --- Acceptance tests for etaf-youtube -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Public behaviour tests.  Every scenario drives the application through the
;; interfaces declared in `etaf-youtube.el' and asserts what a person would
;; see.  The skill transport, the thumbnail downloader and the store are
;; injected, so the suite runs headless, offline and without a browser; the
;; fixtures in tests/fixtures contain only synthetic, public-shaped data.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'etaf)
(require 'etaf-youtube)

(defconst etaf-youtube-tests--fixtures
  (expand-file-name "fixtures" (file-name-directory (or load-file-name
                                                        buffer-file-name)))
  "Fixture directory beside the test source.")

(defconst etaf-youtube-tests--responses
  (expand-file-name "responses.json" etaf-youtube-tests--fixtures)
  "Canned protocol replies keyed by command.")

(defconst etaf-youtube-tests--pixel
  (expand-file-name "pixel.png" etaf-youtube-tests--fixtures)
  "A one-pixel PNG standing in for a downloaded thumbnail.")

(defconst etaf-youtube-tests--fake-skill
  (expand-file-name "fake-skill.sh" etaf-youtube-tests--fixtures)
  "Executable standing in for pi-skill in the process-runner test.")

(defun etaf-youtube-tests--fixture-table ()
  "Return the canned protocol replies as a hash table."
  (with-temp-buffer
    (insert-file-contents etaf-youtube-tests--responses)
    (json-parse-buffer :object-type 'hash-table)))

(defun etaf-youtube-tests--wait (predicate &optional seconds)
  "Wait until PREDICATE is non-nil for at most SECONDS.
Return PREDICATE's final value."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.02)
      (sleep-for 0.01))
    (funcall predicate)))

(defun etaf-youtube-tests--args (argv)
  "Return ARGV's backend arguments, without the command prefix and --json.
The prefix is the program plus, when present, the bundled backend script."
  (let* ((words (cl-remove-if (lambda (argument) (equal argument "--json")) argv))
         (words (if (and (cdr words) (string-suffix-p ".mjs" (cadr words)))
                    (cddr words)
                  (cdr words))))
    words))

(defun etaf-youtube-tests--runner (fixtures &optional log)
  "Return a runner answering from FIXTURES and appending calls to LOG.
LOG is a cons whose car receives argument lists, newest first."
  (lambda (argv callback)
    (let* ((args (etaf-youtube-tests--args argv))
           (key (string-join args " "))
           (payload (gethash key fixtures)))
      (when log
        (setcar log (cons args (car log))))
      (run-at-time
       0.02 nil
       (lambda ()
         (funcall callback
                  (if payload
                      (list :exit 0 :stdout (json-serialize payload))
                    (list :exit 3
                          :stdout (json-serialize
                                   (list :ok nil
                                         :message (format "unsupported: %s" key))))))))
      #'ignore)))

(defun etaf-youtube-tests--thumbnail-fetcher ()
  "Return a fetcher that copies the fixture pixel into the target file."
  (lambda (_images _url file callback)
    (copy-file etaf-youtube-tests--pixel file t)
    (funcall callback nil)
    #'ignore))

(cl-defun etaf-youtube-tests--app (&key (fixtures (etaf-youtube-tests--fixture-table))
                                        log fetcher async (store :none))
  "Create a test session over FIXTURES.
LOG receives the skill calls; FETCHER defaults to the pixel copy; ASYNC uses
a delayed runner instead of the fixture runner; STORE is a store object or
`:none'."
  (let ((directory (make-temp-file "etaf-youtube-thumbs-" t)))
    (etaf-youtube-create
     :service (etaf-youtube-service-create
               :timeout 5
               :runner (if async
                           async
                         (etaf-youtube-tests--runner fixtures log)))
     :images (etaf-youtube-images-create
              :directory directory
              :fetcher (or fetcher (etaf-youtube-tests--thumbnail-fetcher))
              :proxy-fn (lambda () nil))
     :store store)))

(defmacro etaf-youtube-tests--with-app (binding fixtures-sym log-sym &rest body)
  "Run BODY with BINDING bound to a fixture session.
FIXTURES-SYM is bound to the fixture table and LOG-SYM to the call log."
  (declare (indent 3))
  `(let* ((,fixtures-sym (etaf-youtube-tests--fixture-table))
          (,log-sym (list nil))
          (,binding (etaf-youtube-tests--app :fixtures ,fixtures-sym
                                             :log ,log-sym)))
     (unwind-protect
         (progn ,@body)
       (etaf-youtube-destroy ,binding))))

(defun etaf-youtube-tests--calls (log)
  "Return LOG's recorded calls, oldest first."
  (reverse (car log)))

(ert-deftest etaf-youtube-check-records-account ()
  "Opening a session asks the skill for the account and records it."
  (etaf-youtube-tests--with-app app fixtures log
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (etaf-youtube-state app) :account))))
    (let* ((state (etaf-youtube-state app))
           (account (plist-get state :account)))
      (should (plist-get account :signed_in))
      (should (equal "测试用户" (plist-get account :name))))
    (should (equal '("check") (car (etaf-youtube-tests--calls log))))))

(ert-deftest etaf-youtube-home-feed-loads-cards ()
  "The home route loads items, a title and a pagination cursor."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'ready (plist-get (plist-get (etaf-youtube-state app)
                                                         :feed-status)
                                              :state)))))
    (let ((state (etaf-youtube-state app)))
      (should (= 3 (plist-get state :items)))
      (should (equal "cursor-home" (plist-get state :next)))
      (should (equal 'home (plist-get state :view))))
    (should (member '("feed" "home") (etaf-youtube-tests--calls log)))))

(ert-deftest etaf-youtube-load-more-appends-items ()
  "Load-more reads the cursor and appends the next page."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (etaf-youtube-load-more app)
    (should (etaf-youtube-tests--wait
             (lambda () (= 4 (plist-get (etaf-youtube-state app) :items)))))
    (should (null (plist-get (etaf-youtube-state app) :next)))
    (should (member '("more" "cursor-home") (etaf-youtube-tests--calls log)))))

(ert-deftest etaf-youtube-search-sends-the-selected-filter ()
  "Search passes the query and filter to the skill."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-search app "Emacs" "videos")
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'ready (plist-get (plist-get (etaf-youtube-state app)
                                                         :feed-status)
                                              :state)))))
    (should (member '("search" "Emacs" "--filter" "videos")
                    (etaf-youtube-tests--calls log)))
    (should (equal 'search (plist-get (etaf-youtube-state app) :view)))))

(ert-deftest etaf-youtube-watch-loads-video-comments-and-source ()
  "Opening a video reads its details, comments and a playable source."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda ()
               (let* ((state (etaf-youtube-state app))
                      (comments (plist-get state :comments)))
                 (and (eq 'ready (plist-get (plist-get state :media-status) :state))
                      (equal "2" (plist-get comments :count)))))))
    (let* ((state (etaf-youtube-state app))
           (video (plist-get state :video))
           (comments (plist-get state :comments)))
      (should (equal "v1" (plist-get video :id)))
      (should (equal "测试视频一：ETAF 入门" (plist-get video :title)))
      (should (equal "2" (plist-get comments :count)))
      (should (= 125 (plist-get state :duration)))
      (let ((source (etaf-youtube-media-src app)))
        (should (equal 'url (plist-get source :kind)))
        (should (equal "https://media.test/video.m4s?q=720" (plist-get source :url)))
        (should (equal "https://media.test/audio.m4s?q=720"
                       (plist-get source :audio-url)))
        (should (equal "http://127.0.0.1:7890" (plist-get source :proxy)))
        (should (equal '(("User-Agent" . "TestAgent/1.0")
                         ("Accept-Language" . "zh-CN"))
                       (plist-get source :headers)))
        (should (plist-get source :audio))))
    (should (equal '(1080 720 480) (etaf-youtube-quality-choices app)))))

(ert-deftest etaf-youtube-stale-feed-reply-is-dropped ()
  "A reply from a route the user has left never replaces the new list."
  (let* ((fixtures (etaf-youtube-tests--fixture-table))
         (home (gethash "feed home" fixtures))
         (subscriptions (gethash "feed subscriptions" fixtures))
         (delayed nil))
    (let ((app (etaf-youtube-tests--app
                :fixtures fixtures
                :async (lambda (argv callback)
                         (let ((args (etaf-youtube-tests--args argv)))
                           (cond
                            ((equal args '("check"))
                             (run-at-time 0.01 nil
                                          (lambda ()
                                            (funcall callback
                                                     (list :exit 0
                                                           :stdout
                                                           (json-serialize
                                                            (gethash "check" fixtures)))))))
                            ((equal args '("feed" "home"))
                             (setq delayed callback))
                            ((equal args '("feed" "subscriptions"))
                             (run-at-time 0.01 nil
                                          (lambda ()
                                            (funcall callback
                                                     (list :exit 0
                                                           :stdout
                                                           (json-serialize
                                                            subscriptions)))))))
                           #'ignore)))))
      (unwind-protect
          (progn
            (etaf-youtube-locate app 'home)
            (etaf-youtube-locate app 'subscriptions)
            (should (etaf-youtube-tests--wait
                     (lambda () (equal "订阅内容"
                                       (plist-get (etaf-youtube-state app) :title)))))
            (should delayed)
            (funcall delayed (list :exit 0 :stdout (json-serialize home)))
            (sleep-for 0.1)
            (let ((state (etaf-youtube-state app)))
              (should (= 1 (plist-get state :items)))
              (should (equal "订阅内容" (plist-get state :title)))))
        (etaf-youtube-destroy app)))))

(ert-deftest etaf-youtube-player-commands-update-state ()
  "Seek, speed, volume, mute and quality update the session."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'ready (plist-get (plist-get (etaf-youtube-state app)
                                                         :media-status)
                                              :state)))))
    (etaf-youtube-seek app 30)
    (should (= 30 (plist-get (etaf-youtube-state app) :position)))
    (etaf-youtube-seek-by app -10)
    (should (= 20 (plist-get (etaf-youtube-state app) :position)))
    (etaf-youtube-set-volume app 40)
    (etaf-youtube-set-speed app 1.5)
    (etaf-youtube-toggle-mute app)
    (let ((state (etaf-youtube-state app)))
      (should (= 40 (plist-get state :volume)))
      (should (= 1.5 (plist-get state :speed)))
      (should (plist-get state :muted)))
    (etaf-youtube-set-quality app 1080)
    (should (etaf-youtube-tests--wait
             (lambda () (member '("source" "v1" "--quality" "1080")
                                (etaf-youtube-tests--calls log)))))
    (should (= 1080 (plist-get (etaf-youtube-state app) :quality)))))

(ert-deftest etaf-youtube-captions-follow-the-playback-position ()
  "Captions load the track's cues and report the active one at the position."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (etaf-youtube-media-src app))))
    (should-not (etaf-youtube-caption-text app))
    (etaf-youtube-toggle-captions app)
    (should (etaf-youtube-tests--wait
             (lambda () (member '("captions" "v1" "--language" "zh-Hans")
                                (etaf-youtube-tests--calls log)))))
    (should (etaf-youtube-tests--wait
             (lambda () (etaf-youtube-caption-text app))))
    (should (equal "欢迎观看这个演示" (etaf-youtube-caption-text app)))
    (etaf-youtube-seek app 20)
    (should (equal "ETAF 用声明式视图构建文本应用"
                   (etaf-youtube-caption-text app)))
    (etaf-youtube-seek app 10)
    (should-not (etaf-youtube-caption-text app))
    (etaf-youtube-toggle-captions app)
    (etaf-youtube-seek app 2)
    (should-not (etaf-youtube-caption-text app))))

(ert-deftest etaf-youtube-regions-declare-navigable-areas ()
  "The mounted shell names the sidebar, content and comment regions."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (let ((buffer (generate-new-buffer " *etaf-youtube-regions*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (should (etaf-region-focus etaf-youtube-region-shell runtime))
              (should (etaf-region-focus etaf-youtube-region-content runtime))
              (should (etaf-region-focus etaf-youtube-region-sidebar runtime))
              ;; The comment region belongs to the watch page only.
              (should-error (etaf-region-focus etaf-youtube-region-comments runtime)
                            :type 'etaf-event-error)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-resume-round-trip ()
  "A watched position survives leaving the video and returns on reopen."
  (let* ((etaf-youtube-store-file (make-temp-file "etaf-youtube-resume-" nil
                                                  ".sqlite3"))
         (fixtures (etaf-youtube-tests--fixture-table))
         (store (etaf-youtube-store-open))
         (app (etaf-youtube-tests--app :fixtures fixtures :store store)))
    (unwind-protect
        (progn
          (should store)
          (etaf-youtube-open-video app "v1")
          (should (etaf-youtube-tests--wait
                   (lambda () (etaf-youtube-media-src app))))
          (etaf-youtube-seek app 42)
          (etaf-youtube-locate app 'home)
          (should (= 42 (etaf-youtube-store-resume store "v1")))
          (etaf-youtube-open-video app "v1")
          (should (etaf-youtube-tests--wait
                   (lambda () (etaf-youtube-media-src app))))
          (should (= 42 (plist-get (etaf-youtube-state app) :resume))))
      (etaf-youtube-destroy app)
      (etaf-youtube-store-close store))))

(ert-deftest etaf-youtube-writes-need-explicit-confirmation ()
  "A write is previewed without YES and submitted only with it."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (etaf-youtube-state app) :video))))
    (etaf-youtube-like app)
    (should (etaf-youtube-tests--wait
             (lambda () (member '("action" "like" "v1")
                                (etaf-youtube-tests--calls log)))))
    (should-not (member "--yes" (car (etaf-youtube-tests--calls log))))
    (etaf-youtube-like app t)
    (should (etaf-youtube-tests--wait
             (lambda () (member '("action" "like" "v1" "--yes")
                                (etaf-youtube-tests--calls log)))))
    (should (etaf-youtube-tests--wait
             (lambda ()
               (equal "LIKE" (plist-get (plist-get (etaf-youtube-state app) :video)
                                        :like-status)))))
    (should (equal 'success
                   (plist-get (plist-get (etaf-youtube-state app) :message) :variant)))))

(ert-deftest etaf-youtube-comment-submitted-unverified-is-a-warning ()
  "A submitted but unverified comment is reported without being retried."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (etaf-youtube-state app) :video))))
    (etaf-youtube-comment app "你好" t)
    (should (etaf-youtube-tests--wait
             (lambda ()
               (member '("action" "comment" "v1" "--text" "你好" "--yes")
                       (etaf-youtube-tests--calls log)))))
    (should (etaf-youtube-tests--wait
             (lambda ()
               (eq 'warning
                   (plist-get (plist-get (etaf-youtube-state app) :message)
                              :variant)))))
    (should (= 1 (cl-count '("action" "comment" "v1" "--text" "你好" "--yes")
                           (etaf-youtube-tests--calls log)
                           :test #'equal)))))

(ert-deftest etaf-youtube-selection-and-activation ()
  "Selection moves within the list and activation opens the video."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (should-not (plist-get (etaf-youtube-state app) :selected))
    (etaf-youtube-activate app)
    (should (eq 'home (plist-get (etaf-youtube-state app) :view)))
    (etaf-youtube-select app 1)
    (should (= 0 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-select app 1)
    (should (= 1 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-select app -1)
    (should (= 0 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-activate app)
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'watch (plist-get (etaf-youtube-state app) :view)))))
    (should (member '("video" "v1") (etaf-youtube-tests--calls log)))
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (should-not (plist-get (etaf-youtube-state app) :selected))
    (etaf-youtube-select app -1)
    (should (= 2 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-select app -100)
    (should (= 0 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-select app 100)
    (should (= 2 (plist-get (etaf-youtube-state app) :selected)))))

(ert-deftest etaf-youtube-back-retraces-history ()
  "Back returns to the previous route and reloads it."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'watch (plist-get (etaf-youtube-state app) :view)))))
    (etaf-youtube-back app)
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'home (plist-get (etaf-youtube-state app) :view)))))
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))))

(ert-deftest etaf-youtube-chips-switch-channel-tabs ()
  "A channel tab chip browses the same channel with its params."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'channel (list :id "UC1"))
    (should (etaf-youtube-tests--wait
             (lambda () (equal "测试频道" (plist-get (etaf-youtube-state app)
                                                     :title)))))
    (etaf-youtube-apply-chip app '(:title "Shorts" :selected nil
                                   :params "tab-shorts" :id "shorts"))
    (should (etaf-youtube-tests--wait
             (lambda () (member '("browse" "UC1" "--params" "tab-shorts")
                                (etaf-youtube-tests--calls log)))))
    (should (etaf-youtube-tests--wait
             (lambda () (= 1 (plist-get (etaf-youtube-state app) :items)))))))

(ert-deftest etaf-youtube-replies-load-per-comment ()
  "Replies load through the comment's own cursor."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda ()
               (equal "2" (plist-get (plist-get (etaf-youtube-state app)
                                                 :comments)
                                      :count)))))
    (etaf-youtube-load-replies app "c1")
    (should (etaf-youtube-tests--wait
             (lambda () (etaf-youtube-replies app "c1"))))
    (should (equal "一条回复。" (plist-get (car (etaf-youtube-replies app "c1"))
                                          :text)))
    (should (member '("more" "cursor-replies-c1")
                    (etaf-youtube-tests--calls log)))))

(ert-deftest etaf-youtube-theme-sidebar-and-theater ()
  "Appearance and layout choices are reported in the state."
  (etaf-youtube-tests--with-app app fixtures log
    (should (eq 'dark (plist-get (etaf-youtube-state app) :theme)))
    (etaf-youtube-cycle-theme app)
    (should (eq 'light (plist-get (etaf-youtube-state app) :theme)))
    (etaf-youtube-toggle-sidebar app)
    (etaf-youtube-toggle-theater app)
    (let ((state (etaf-youtube-state app)))
      (should-not (plist-get state :sidebar))
      (should (plist-get state :theater)))
    (should-not (equal (etaf-youtube-color :bg)
                       (etaf-youtube-color :bg 'light)))
    (should (equal (etaf-youtube-color :bg 'light)
                   (plist-get (etaf-youtube-theme-defaults 'light) :paper)))))

(etaf-define-component etaf-youtube-tests--framing-host (&key surface app)
  "Provide SURFACE to the client APP and render it below."
  :setup (etaf-surface-provide surface)
  :render (etaf-youtube-view app))

(defun etaf-youtube-tests--row-painting (buffer color)
  "Return the first position in BUFFER whose face paints COLOR as background."
  (with-current-buffer buffer
    (let ((pos (point-min))
          found)
      (while (and (< pos (point-max)) (not found))
        (when (equal color
                     (plist-get (get-text-property pos 'face) :background))
          (setq found pos))
        (setq pos (1+ pos)))
      found)))

(defun etaf-youtube-tests--painted-background (buffer position)
  "Return the background BUFFER paints at POSITION."
  (with-current-buffer buffer
    (plist-get (get-text-property position 'face) :background)))

(ert-deftest etaf-youtube-declares-its-surface-to-a-host ()
  "A host frames the client from the surface the client declares.
The panel's title-bar switch writes the session's mode cell, so the video page
repaints instead of only the frame chrome."
  (etaf-youtube-tests--with-app app fixtures log
    (let* ((surface (etaf-surface-create))
           (buffer (generate-new-buffer " *etaf-youtube framing host*")))
      (unwind-protect
          (progn
            (etaf-mount buffer
                        (etaf-view (etaf-youtube-tests--framing-host
                                    :surface surface :app app))
                        (list :viewport-width 1200 :viewport-height 40))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (should (equal '((light . "亮") (dark . "暗"))
                           (etaf-surface-modes surface)))
            (let* ((before (plist-get (etaf-value (etaf-surface-theme surface))
                                      :paper))
                   (pos (etaf-youtube-tests--row-painting buffer before)))
              (should pos)
              (etaf-set-value (etaf-surface-mode surface) 'light)
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (should (eq 'light (etaf-value (etaf-surface-mode surface))))
              (should-not (equal before
                                 (plist-get (etaf-value (etaf-surface-theme surface))
                                            :paper)))
              (should (equal (plist-get (etaf-value (etaf-surface-theme surface))
                                        :paper)
                             (etaf-youtube-tests--painted-background buffer pos)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))

(ert-deftest etaf-youtube-thumbnails-load-through-the-injected-fetcher ()
  "Requesting a thumbnail stores a descriptor and bumps the version."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (let* ((directory (make-temp-file "etaf-youtube-thumbs-test-" t))
         (images (etaf-youtube-images-create
                  :directory directory
                  :fetcher (etaf-youtube-tests--thumbnail-fetcher)
                  :proxy-fn (lambda () nil)))
         (version (etaf-youtube-images-version images)))
    (should (etaf-youtube-images-request images "https://i.ytimg.com/vi/x/hq720.jpg"))
    (should (etaf-youtube-tests--wait
             (lambda () (etaf-youtube-images-descriptor
                         images "https://i.ytimg.com/vi/x/hq720.jpg"))))
    (should (> (etaf-value version) 0))
    ;; The descriptor must point at a readable file, not the temporary path.
    (let ((image (etaf-youtube-images-descriptor
                  images "https://i.ytimg.com/vi/x/hq720.jpg")))
      (should (file-exists-p (plist-get (cdr image) :file))))
    (should-not (etaf-youtube-images-request
                 images "https://i.ytimg.com/vi/x/hq720.jpg"))
    (etaf-youtube-images-cancel images)))

(ert-deftest etaf-youtube-view-mounts-with-list-content ()
  "The mounted shell renders the loaded list inside an ETAF buffer."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (let ((buffer (generate-new-buffer " *etaf-youtube-test-view*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (with-current-buffer buffer
              (should (string-match-p "测试视频一" (buffer-string)))
              (should (string-match-p "首页" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-destroy-releases-the-session ()
  "Destroy cancels requests, the player timer and the store."
  (let* ((table (etaf-youtube-tests--fixture-table))
         (app (etaf-youtube-tests--app :fixtures table)))
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'ready (plist-get (plist-get (etaf-youtube-state app)
                                                         :media-status)
                                              :state)))))
    (should (etaf-youtube-destroy app))
    (should (etaf-youtube-destroy app))
    (should (null (plist-get (etaf-youtube-state app) :playing)))))

(ert-deftest etaf-youtube-process-runner-reads-skill-json ()
  "The default process runner drains a real child and parses its JSON.
The fake skill is an executable script, so this exercises process creation,
pipe draining, exit-status handling and JSON decoding without a browser."
  (let* ((service (etaf-youtube-service-create :timeout 10))
         (etaf-youtube-command (list etaf-youtube-tests--fake-skill))
         (result nil))
    (etaf-youtube-service-call service '("check")
                               (lambda (value) (setq result value))
                               :process-test)
    (should (etaf-youtube-tests--wait (lambda () result)))
    (should (eq 'ok (plist-get result :status)))
    (should (equal "Process Runner" (plist-get (plist-get result :value) :name)))
    (etaf-youtube-service-close service)))

(ert-deftest etaf-youtube-login-reports-the-account-from-the-backend ()
  "Signing in goes through the bundled backend and reloads the session.
The fixture answers `check' with a signed-in account, so this covers the
command wiring, the login-then-check order and the refresh without a browser."
  (let* ((log (list nil))
         (app (etaf-youtube-tests--app :log log)))
    (etaf-youtube-login app)
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (plist-get (etaf-youtube-state app) :account) :name))))
    (should (member '("login") (car log)))
    (should (member '("check") (car log)))
    (should (equal "测试用户"
                   (plist-get (plist-get (etaf-youtube-state app) :account) :name)))
    (etaf-youtube-destroy app)))

(ert-deftest etaf-youtube-thumbnails-strip-signed-query ()
  "Signed YouTube thumbnail tokens are dropped before downloading.
The token makes the CDN answer with AVIF while the unsigned URL serves a
JPEG, so the fetcher must receive the unsigned address while the cache still
keys the original URL."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (let* ((directory (make-temp-file "etaf-youtube-unsigned-" t))
         (seen nil)
         (images (etaf-youtube-images-create
                  :directory directory
                  :fetcher (lambda (_images url file callback)
                             (setq seen url)
                             (copy-file etaf-youtube-tests--pixel file t)
                             (funcall callback nil)
                             #'ignore)
                  :proxy-fn (lambda () nil))))
    (etaf-youtube-images-request
     images "https://i.ytimg.com/vi/x/hq720.jpg?sqp=token&rs=abc")
    (should (etaf-youtube-tests--wait (lambda () seen)))
    (should (equal "https://i.ytimg.com/vi/x/hq720.jpg" seen))
    (let ((image (etaf-youtube-images-descriptor
                  images "https://i.ytimg.com/vi/x/hq720.jpg?sqp=token&rs=abc")))
      (should image)
      (should (file-exists-p (plist-get (cdr image) :file))))))

(ert-deftest etaf-youtube-thumbnail-disk-cache-survives-reopen ()
  "A cached thumbnail file is still there when a later session reads it.
The disk cache is keyed by the original URL; reopening must reuse the file
instead of deleting the target it just found."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (let* ((directory (make-temp-file "etaf-youtube-reopen-" t))
         (url "https://i.ytimg.com/vi/cache/hq720.jpg")
         (first (etaf-youtube-images-create
                 :directory directory
                 :fetcher (etaf-youtube-tests--thumbnail-fetcher)
                 :proxy-fn (lambda () nil)))
         (second (etaf-youtube-images-create
                  :directory directory
                  :fetcher (lambda (_images _url _file callback)
                             (funcall callback "must not download again")
                             #'ignore)
                  :proxy-fn (lambda () nil))))
    (etaf-youtube-images-request first url)
    (should (etaf-youtube-tests--wait
             (lambda () (etaf-youtube-images-descriptor first url))))
    (etaf-youtube-images-request second url)
    (should (etaf-youtube-tests--wait
             (lambda () (etaf-youtube-images-descriptor second url))))
    (let ((image (etaf-youtube-images-descriptor second url)))
      (should image)
      (should (file-exists-p (plist-get (cdr image) :file))))))

(ert-deftest etaf-youtube-thumbnail-404-falls-back-on-the-working-route ()
  "Missing custom artwork uses a JPEG fallback without changing network route."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (let* ((root (make-temp-file "youtube-curl-" t))
         (trace (expand-file-name "trace" root))
         (bin (expand-file-name "bin" root))
         (process-environment (copy-sequence process-environment))
         (exec-path (cons bin exec-path))
         (images (etaf-youtube-images-create
                  :directory (expand-file-name "cache" root)
                  :proxy-fn (lambda () "http://proxy.test:9")))
         (url "https://i.ytimg.com/vi/test/hq720_custom_1.jpg?sqp=fixture"))
    (unwind-protect
        (progn
          (make-directory bin)
          (copy-file (expand-file-name "fake-curl.sh" etaf-youtube-tests--fixtures)
                     (expand-file-name "curl" bin))
          (set-file-modes (expand-file-name "curl" bin) #o755)
          (setenv "YOUTUBE_IMAGE_TRACE" trace)
          (setenv "YOUTUBE_IMAGE_FIXTURE" etaf-youtube-tests--pixel)
          (setenv "HTTPS_PROXY" "http://dead.invalid:9")
          (setenv "no_proxy" "*")
          (etaf-youtube-images-request images url)
          (should (etaf-youtube-tests--wait
                   (lambda () (etaf-youtube-images-descriptor images url))))
          (let ((calls (with-temp-buffer
                         (insert-file-contents trace)
                         (split-string (buffer-string) "\n" t))))
            (should (equal calls
                           '("https://i.ytimg.com/vi/test/hq720_custom_1.jpg|proxy=http://proxy.test:9|bypass="
                             "https://i.ytimg.com/vi/test/hqdefault.jpg|proxy=http://proxy.test:9|bypass=")))))
      (etaf-youtube-images-cancel images)
      (delete-directory root t))))

(ert-deftest etaf-youtube-shorts-and-search-follow-the-application-theme ()
  "Shorts retain their label; search has explicit dark and light colors."
  (dolist (mode '(dark light))
    (let ((tokens (etaf-youtube-theme-defaults mode)))
      (should (equal (plist-get tokens :ui-search-bg)
                     (etaf-youtube-color :panel2 mode)))
      (should (equal (plist-get tokens :ui-search-fg)
                     (etaf-youtube-color :ink mode)))))
  (etaf-youtube-tests--with-app app fixtures log
    (let* ((feed (gethash "feed home" fixtures))
           (short (aref (gethash "items" feed) 2)))
      (puthash "duration" "Shorts" short)
      (puthash "title" "A short clip" short))
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (let ((buffer (generate-new-buffer " *youtube-short-view*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (short (etaf-youtube-tests--host runtime :aria-label "A short clip")))
              (etaf-scroll-into-view runtime short 'end)
              (etaf-runtime-flush runtime))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "A short clip" text))
                (should-not (string-match-p "0:00" text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-refresh-retries-failed-artwork ()
  "Refreshing a feed retries its failed pictures without discarding successes."
  (skip-unless (and (display-graphic-p) (image-type-available-p 'png)))
  (let* ((root (make-temp-file "youtube-retry-" t))
         (ready nil)
         (images (etaf-youtube-images-create
                  :directory root :proxy-fn (lambda () nil)
                  :fetcher (lambda (_images _url file callback)
                             (if ready
                                 (progn (copy-file etaf-youtube-tests--pixel file t)
                                        (funcall callback nil))
                               (funcall callback "temporary transport failure"))
                             #'ignore)))
         (app (etaf-youtube-create
               :images images :store :none
               :service (etaf-youtube-service-create
                         :runner (etaf-youtube-tests--runner
                                  (etaf-youtube-tests--fixture-table))))))
    (unwind-protect
        (progn
          (etaf-youtube-locate app 'home)
          (should (etaf-youtube-tests--wait
                   (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
          (should-not (etaf-youtube-images-descriptor
                       images "https://i.ytimg.com/vi/v1/hq720.jpg"))
          (setq ready t)
          (etaf-youtube-refresh app)
          (should (etaf-youtube-tests--wait
                   (lambda () (etaf-youtube-images-descriptor
                               images "https://i.ytimg.com/vi/v1/hq720.jpg")))))
      (etaf-youtube-destroy app)
      (delete-directory root t))))

(defun etaf-youtube-tests--host (runtime property value)
  "Find the rendered Host whose public PROPERTY equals VALUE in RUNTIME."
  (car (seq-find (lambda (entry) (equal (plist-get (cdr entry) property) value))
                 (etaf-runtime-host-props-entries runtime))))

(ert-deftest etaf-youtube-header-keeps-its-slot-across-updates ()
  "Account arrival, scrolling, palette and size changes keep the full header."
  (etaf-youtube-tests--with-app app fixtures log
    (let* ((feed (gethash "feed home" fixtures))
           (sample (aref (gethash "items" feed) 0))
           (buffer (generate-new-buffer " *youtube-header-test*")))
      (puthash "items" (vconcat
                        (cl-loop for i below 36 collect
                                 (let ((item (copy-hash-table sample)))
                                   (puthash "id" (format "card-%d" i) item)
                                   (puthash "thumbnail" "" item)
                                   item))) feed)
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        '(:viewport-width 1120 :viewport-height 36))
            (should (etaf-youtube-tests--wait
                     (lambda () (= 36 (plist-get (etaf-youtube-state app) :items)))))
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (banner (etaf-youtube-tests--host runtime :role 'banner)))
              (should banner)
              (dolist (size '((1120 . 36) (700 . 28) (420 . 22) (1120 . 15)))
                (etaf-runtime-refit runtime (car size) (cdr size))
                (dolist (mode '(dark light))
                  (etaf-youtube-set-theme app mode)
                  (let* ((content (car (seq-find
                                        (lambda (entry)
                                          (eq (plist-get (plist-get (cdr entry) :region) :id)
                                              etaf-youtube-region-content))
                                        (etaf-runtime-host-props-entries runtime))))
                         (offset (etaf-scroll-to runtime content 'end)))
                    (etaf-runtime-flush runtime)
                    (let* ((span (etaf-host-ref-bounds runtime banner))
                           (size (etaf-host-ref-size runtime banner))
                           (visible (with-current-buffer buffer
                                      (buffer-substring-no-properties (car span) (cdr span)))))
                      (should (> offset 0))
                      (should (= (cdr size) 3))
                      (let* ((avatar (etaf-youtube-tests--host runtime :aria-label "测试用户"))
                             (height (and avatar (cdr (etaf-host-ref-size runtime avatar)))))
                        (should (equal height 1)))
                      (should (string-match-p "搜索" visible))
                      (with-current-buffer buffer (should-not header-line-format))))))
              (etaf-youtube-refresh app)
              (should (etaf-youtube-tests--wait
                       (lambda () (eq (plist-get (plist-get (etaf-youtube-state app) :feed-status)
                                                 :state) 'ready))))
              (let ((height (cdr (etaf-host-ref-size runtime banner))))
                (should (= height 3)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-navigation-selection-suppresses-hover ()
  "Expanded and compact navigation use the same selected-state semantics."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (let ((buffer (generate-new-buffer " *youtube-navigation-test*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        '(:viewport-width 1120 :viewport-height 36))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (dolist (width '(1120 420))
                (etaf-runtime-refit runtime width 36)
                (let* ((entries (etaf-runtime-host-props-entries runtime))
                       (home (seq-find
                              (lambda (entry)
                                (and (equal (plist-get (cdr entry) :aria-label) "首页")
                                     (plist-get (cdr entry) :aria-selected))) entries)))
                  (should home)
                  (should-not (plist-get (cdr home) :hover-style))))
              (etaf-runtime-refit runtime 1120 14)
              (let* ((sidebar (car (seq-find
                                   (lambda (entry)
                                     (eq (plist-get (plist-get (cdr entry) :region) :id)
                                         etaf-youtube-region-sidebar))
                                   (etaf-runtime-host-props-entries runtime))))
                     (offset (etaf-scroll-to runtime sidebar 'end)))
                (etaf-runtime-flush runtime)
                (should (> offset 0))
                (with-current-buffer buffer
                  (let ((visible (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "喜欢的视频" visible)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-grouped-cards-activate-the-original-video ()
  "Grouping portrait cards does not change the target of a card activation."
  (etaf-youtube-tests--with-app app fixtures log
    (let* ((feed (gethash "feed home" fixtures))
           (items (gethash "items" feed))
           (short (aref items 0))
           (buffer (generate-new-buffer " *youtube-card-order-test*"))
           (opened nil))
      (puthash "kind" "short" short)
      (puthash "title" "Portrait first in source" short)
      (etaf-youtube-locate app 'home)
      (should (etaf-youtube-tests--wait
               (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        '(:viewport-width 1120 :viewport-height 40))
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (target (etaf-youtube-tests--host runtime :aria-label
                                                    "Portrait first in source")))
              (should target)
              (should-not (plist-get (etaf-runtime-host-props-for runtime target)
                                     :aria-selected))
              (dolist (change '((0 . t) (1 . nil) (-1 . t)))
                (etaf-youtube-select app (car change))
                (etaf-runtime-flush runtime)
                (let ((selected (plist-get (etaf-runtime-host-props-for runtime target)
                                           :aria-selected)))
                  (should (eq selected (cdr change)))))
              (cl-letf (((symbol-function 'etaf-youtube-open-video)
                         (lambda (_app id) (setq opened id))))
                (etaf-dispatch-event runtime target 'press))
              (should (equal opened (gethash "id" short)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-open-follows-the-usable-window ()
  "Opening and folding the sidebar use the same viewport as automatic refit."
  (etaf-youtube-tests--with-app app fixtures log
    (let ((etaf-youtube-buffer-name " *youtube-window-fit-test*"))
      (save-window-excursion
        (unwind-protect
            (cl-letf (((symbol-function 'etaf-youtube-create)
                       (lambda (&rest _options) app)))
              (etaf-youtube-open)
              (let* ((runtime (etaf-runtime-for-buffer etaf-youtube-buffer-name))
                     (mounted (etaf-runtime-viewport runtime))
                     (fitted (etaf-refit runtime (selected-window))))
                (should (equal mounted fitted))
                (etaf-youtube-toggle-sidebar app)
                (etaf-runtime-flush runtime)
                (let ((folded (etaf-runtime-viewport runtime)))
                  (should (equal fitted folded)))))
          (etaf-youtube-close))))))

(ert-deftest etaf-youtube-open-hides-the-native-caret ()
  "The point caret does not draw a second selection over navigation content."
  (etaf-youtube-tests--with-app app _fixtures _log
    (let ((etaf-youtube-buffer-name " *youtube-caret-test*"))
      (save-window-excursion
        (unwind-protect
            (cl-letf (((symbol-function 'etaf-youtube-create)
                       (lambda (&rest _options) app)))
              (etaf-youtube-open)
              (should-not (buffer-local-value 'cursor-type
                                              (get-buffer etaf-youtube-buffer-name))))
          (etaf-youtube-close))))))

;; Requires etaf-app canvas painting: before it the canvas kept Emacs's
;; default face around the View.
(ert-deftest etaf-youtube-open-canvas-follows-the-appearance ()
  "The canvas around the View uses the application's appearance and follows it."
  (etaf-youtube-tests--with-app app _fixtures _log
    (let ((etaf-youtube-buffer-name " *youtube-canvas-test*"))
      (save-window-excursion
        (unwind-protect
            (cl-letf (((symbol-function 'etaf-youtube-create)
                       (lambda (&rest _options) app)))
              (let* ((buffer (etaf-youtube-open))
                     (canvas
                      (lambda ()
                        (with-current-buffer buffer
                          (plist-get (car (last (alist-get 'default
                                                           face-remapping-alist)))
                                     :background))))
                     (expected
                      (lambda ()
                        (etaf-youtube-color
                         :bg (etaf-value (plist-get app :theme-mode)))))
                     (before (funcall canvas)))
                (should (equal before (funcall expected)))
                (etaf-youtube-cycle-theme app)
                (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
                (let ((after (funcall canvas)))
                  (should-not (equal after before))
                  (should (equal after (funcall expected))))))
          (etaf-youtube-close))))))

(ert-deftest etaf-youtube-subscribe-sends-channel-id ()
  "Subscribe and unsubscribe pass the author's channel id, not the video id."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (etaf-youtube-state app) :video))))
    (etaf-youtube-subscribe app t t)
    (should (etaf-youtube-tests--wait
             (lambda ()
               (eq t (plist-get (plist-get (etaf-youtube-state app) :video)
                                :subscribed)))))
    (should (member '("action" "subscribe" "UC1" "--yes")
                    (etaf-youtube-tests--calls log)))
    (etaf-youtube-subscribe app nil t)
    (should (etaf-youtube-tests--wait
             (lambda ()
               (null (plist-get (plist-get (etaf-youtube-state app) :video)
                                :subscribed)))))
    (should (member '("action" "unsubscribe" "UC1" "--yes")
                    (etaf-youtube-tests--calls log)))))

(ert-deftest etaf-youtube-preview-does-not-mutate-video-state ()
  "Preview writes never mutate local rating state; confirmed unrate resets it."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (etaf-youtube-state app) :video))))
    (etaf-youtube-like app)
    (should (etaf-youtube-tests--wait
             (lambda () (plist-get (etaf-youtube-state app) :message))))
    (should (equal "INDIFFERENT"
                   (plist-get (plist-get (etaf-youtube-state app) :video)
                              :like-status)))
    (etaf-youtube-like app t)
    (should (etaf-youtube-tests--wait
             (lambda ()
               (equal "LIKE" (plist-get (plist-get (etaf-youtube-state app) :video)
                                        :like-status)))))
    (etaf-youtube-unrate app t)
    (should (etaf-youtube-tests--wait
             (lambda ()
               (equal "INDIFFERENT"
                      (plist-get (plist-get (etaf-youtube-state app) :video)
                                 :like-status)))))))

(ert-deftest etaf-youtube-media-src-normalizes-empty-proxy-and-audio ()
  "Empty-string proxy and audio_url become nil so etaf-video accepts direct routes."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v-direct")
    (should (etaf-youtube-tests--wait (lambda () (etaf-youtube-media-src app))))
    (let ((src (etaf-youtube-media-src app)))
      (should (null (plist-get src :proxy)))
      (should (null (plist-get src :audio-url)))
      (should (equal "https://media.test/videoplayback?q=720"
                     (plist-get src :url)))
      (should (= 2 (plist-get (etaf-youtube-state app) :chapters))))))

(ert-deftest etaf-youtube-streams-switch-quality-in-place ()
  "When media carries a full stream ladder, quality switches in place at current time."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v-direct")
    (should (etaf-youtube-tests--wait (lambda () (etaf-youtube-media-src app))))
    (etaf-youtube-seek app 45)
    (let ((before-source-calls
           (cl-count-if (lambda (c) (equal (car c) "source"))
                        (etaf-youtube-tests--calls log))))
      (etaf-youtube-set-quality app 1080)
      (let ((src (etaf-youtube-media-src app))
            (after-source-calls
             (cl-count-if (lambda (c) (equal (car c) "source"))
                          (etaf-youtube-tests--calls log))))
        (should (= before-source-calls after-source-calls))
        (should (equal "https://media.test/videoplayback?q=1080"
                       (plist-get src :url)))
        (should (equal "https://media.test/videoplayback?a=1080"
                       (plist-get src :audio-url)))
        (should (= 45.0 (plist-get src :start)))
        (should (= 1080 (plist-get (etaf-youtube-state app) :quality)))))))

(ert-deftest etaf-youtube-ret-activates-focused-control-before-card ()
  "Pressing RET activates the focused interactive control instead of ignoring focus."
  (etaf-youtube-tests--with-app app fixtures log
    (let ((etaf-youtube-buffer-name " *youtube-ret-focus-test*"))
      (save-window-excursion
        (unwind-protect
            (cl-letf (((symbol-function 'etaf-youtube-create)
                       (lambda (&rest _options) app)))
              (let ((buffer (etaf-youtube-open)))
                (should (etaf-youtube-tests--wait
                         (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
                (let* ((runtime (etaf-runtime-for-buffer buffer))
                       (subs (etaf-youtube-tests--host runtime :aria-label "订阅内容")))
                  (should subs)
                  (etaf-focus runtime subs)
                  (with-current-buffer buffer
                    (let ((cmd (key-binding (kbd "RET"))))
                      (should (commandp cmd))
                      (call-interactively cmd)))
                  (should (etaf-youtube-tests--wait
                           (lambda () (eq 'subscriptions
                                          (plist-get (etaf-youtube-state app) :view))))))))
          (etaf-youtube-close))))))

(ert-deftest etaf-youtube-doctor-reports-required-and-optional-facts ()
  "Doctor returns valid required/optional facts without unshipped build commands."
  (let ((facts (etaf-youtube-doctor)))
    (should (consp (plist-get facts :required)))
    (should (consp (plist-get facts :optional)))
    (dolist (section '(:required :optional))
      (dolist (fact (plist-get facts section))
        (should (stringp (nth 0 fact)))
        (should (booleanp (nth 1 fact)))
        (should (stringp (nth 2 fact)))
        (should-not (string-empty-p (nth 2 fact)))
        (should-not (string-match-p "make native-build\\|elpa/.*make" (nth 2 fact)))))))

(ert-deftest etaf-youtube-open-preserves-mode-line ()
  "Opening the application preserves the user's Emacs mode-line."
  (etaf-youtube-tests--with-app app _fixtures _log
    (let ((etaf-youtube-buffer-name " *youtube-modeline-test*"))
      (save-window-excursion
        (unwind-protect
            (cl-letf (((symbol-function 'etaf-youtube-create)
                       (lambda (&rest _options) app)))
              (let ((buffer (etaf-youtube-open)))
                (should (buffer-local-value 'mode-line-format buffer))))
          (etaf-youtube-close))))))

(ert-deftest etaf-youtube-watch-view-mounts-with-workbench-region ()
  "Opening a video renders the cinema watch view and exposes the comments region."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-open-video app "v1")
    (should (etaf-youtube-tests--wait
             (lambda () (and (plist-get (etaf-youtube-state app) :video)
                             (etaf-youtube-media-src app)))))
    (let ((buffer (generate-new-buffer " *etaf-youtube-watch-mount*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (should (etaf-region-focus etaf-youtube-region-content runtime))
              (should (etaf-region-focus etaf-youtube-region-comments runtime)))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "测试视频一" text))
                (should (string-match-p "简介" text))
                (should (string-match-p "字幕" text))
                (should (string-match-p "评论" text))))
            ;; Also switch to comments tab and ensure comment composer renders cleanly
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (comments-tab (etaf-youtube-tests--host runtime :aria-label "评论")))
              (should comments-tab)
              (etaf-dispatch-event runtime comments-tab 'press)
              (etaf-runtime-flush runtime)
              (with-current-buffer buffer
                (should (string-match-p "发布" (buffer-substring-no-properties (point-min) (point-max)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-selection-keeps-invariant-geometry ()
  "Selecting sidebar items, search filters, cards, and watch tabs never shifts geometry."
  (etaf-youtube-tests--with-app app fixtures log
    (etaf-youtube-locate app 'home)
    (should (etaf-youtube-tests--wait
             (lambda () (= 3 (plist-get (etaf-youtube-state app) :items)))))
    (let ((buffer (generate-new-buffer " *etaf-youtube-zero-jitter*")))
      (unwind-protect
          (progn
            (etaf-mount buffer (etaf-youtube-view app)
                        '(:viewport-width 1200 :viewport-height 40))
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (card0 (etaf-youtube-tests--host runtime :aria-label "测试视频一：ETAF 入门"))
                   (card1 (etaf-youtube-tests--host runtime :aria-label "测试视频二：播放列表概览"))
                   (c0-before (etaf-host-ref-bounds runtime card0))
                   (c1-before (etaf-host-ref-bounds runtime card1))
                   (c0-size-before (etaf-host-ref-size runtime card0))
                   (c1-size-before (etaf-host-ref-size runtime card1))
                   (home-nav (etaf-youtube-tests--host runtime :aria-label "首页"))
                   (shorts-nav (etaf-youtube-tests--host runtime :aria-label "Shorts"))
                   (home-size-before (etaf-host-ref-size runtime home-nav))
                   (shorts-size-before (etaf-host-ref-size runtime shorts-nav)))
              ;; Card selection keeps exact same bounds & dimensions
              (etaf-youtube-select app 0)
              (etaf-runtime-flush runtime)
              (should (equal c0-before (etaf-host-ref-bounds runtime card0)))
              (should (equal c1-before (etaf-host-ref-bounds runtime card1)))
              (should (equal c0-size-before (etaf-host-ref-size runtime card0)))
              (should (equal c1-size-before (etaf-host-ref-size runtime card1)))
              (etaf-youtube-select app 1)
              (etaf-runtime-flush runtime)
              (should (equal c0-before (etaf-host-ref-bounds runtime card0)))
              (should (equal c1-before (etaf-host-ref-bounds runtime card1)))
              ;; Sidebar switch keeps exact same item sizes
              (etaf-youtube-locate app 'shorts)
              (should (etaf-youtube-tests--wait
                       (lambda () (eq 'shorts (plist-get (etaf-youtube-state app) :view)))))
              (etaf-runtime-flush runtime)
              (should (equal home-size-before
                             (etaf-host-ref-size
                              runtime (etaf-youtube-tests--host runtime :aria-label "首页"))))
              (should (equal shorts-size-before
                             (etaf-host-ref-size
                              runtime (etaf-youtube-tests--host runtime :aria-label "Shorts")))))
            ;; Watch Workbench tab switch keeps every tab at identical bounds & sizes
            (etaf-youtube-open-video app "v1")
            (should (etaf-youtube-tests--wait
                     (lambda () (and (plist-get (etaf-youtube-state app) :video)
                                     (etaf-youtube-media-src app)))))
            (let* ((runtime (etaf-runtime-for-buffer buffer))
                   (_ (etaf-runtime-flush runtime))
                   (labels '("简介" "字幕" "评论" "推荐"))
                   (before (mapcar (lambda (lbl)
                                     (let ((h (etaf-youtube-tests--host runtime :aria-label lbl)))
                                       (list lbl (etaf-host-ref-bounds runtime h)
                                             (etaf-host-ref-size runtime h))))
                                   labels)))
              (dolist (target '("字幕" "评论" "推荐" "简介"))
                (let ((tab (etaf-youtube-tests--host runtime :aria-label target)))
                  (should tab)
                  (etaf-dispatch-event runtime tab 'press)
                  (etaf-runtime-flush runtime)
                  (dolist (entry before)
                    (let ((h (etaf-youtube-tests--host runtime :aria-label (nth 0 entry))))
                      (should (equal (nth 1 entry) (etaf-host-ref-bounds runtime h)))
                      (should (equal (nth 2 entry) (etaf-host-ref-size runtime h)))))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-watch-loading-and-buffering-transition ()
  "Watch view shows an animated loading/buffering overlay until frames present and on stall."
  (etaf-youtube-tests--with-app app fixtures log
    (let ((buffer (generate-new-buffer " *etaf-youtube-loading-transition*"))
          (fake-player-state (list :engine 'mpv :playing t :buffering t
                                   :presented 0 :position 0.0 :duration 293.0
                                   :error nil :ended nil)))
      (unwind-protect
          (cl-letf (((symbol-function 'etaf-video-state)
                     (lambda (_handle) fake-player-state)))
            (etaf-mount buffer (etaf-youtube-view app)
                        '(:viewport-width 1200 :viewport-height 40))
            (etaf-youtube-open-video app "v1")
            (should (etaf-youtube-tests--wait
                     (lambda () (and (plist-get (etaf-youtube-state app) :video)
                                     (etaf-youtube-media-src app)))))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              ;; Phase 1: media resolved, awaiting first decoded frame (presented = 0).
              (etaf-runtime-flush runtime)
              (should (plist-get (etaf-youtube-state app) :buffering))
              (should-not (plist-get (etaf-youtube-state app) :has-frame))
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "正在连接 libmpv\\|正在缓冲" text))
                  (should-not (string-match-p "● libmpv" text))))
              ;; Phase 2: first frame arrives (presented > 0, buffering nil).
              (setq fake-player-state
                    (list :engine 'mpv :playing t :buffering nil
                          :presented 4 :position 1.2 :duration 293.0
                          :error nil :ended nil))
              (should (etaf-youtube-tests--wait
                       (lambda () (and (plist-get (etaf-youtube-state app) :has-frame)
                                       (not (plist-get (etaf-youtube-state app) :buffering))))))
              (etaf-runtime-flush runtime)
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should-not (string-match-p "正在缓冲\\|正在连接 libmpv" text))))
              ;; Phase 3: mid-playback stall / seek rebuffering re-shows compact pill.
              (setq fake-player-state
                    (list :engine 'mpv :playing t :buffering t
                          :presented 4 :position 33.0 :duration 293.0
                          :error nil :ended nil))
              (should (etaf-youtube-tests--wait
                       (lambda () (plist-get (etaf-youtube-state app) :buffering))))
              (etaf-runtime-flush runtime)
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "正在缓冲" text))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest etaf-youtube-watch-fullscreen-modes-and-shared-cinema-deck ()
  "Watch View supports two-tier Pure Fullscreen sharing the aligned cinema deck."
  (etaf-youtube-tests--with-app app fixtures log
    (let ((buffer (generate-new-buffer " *etaf-youtube-fullscreen*")))
      (unwind-protect
          (progn
            (plist-put app :buffer buffer)
            (etaf-mount buffer (etaf-youtube-view app)
                        '(:viewport-width 1200 :viewport-height 40))
            (etaf-youtube-open-video app "v1")
            (should (etaf-youtube-tests--wait
                     (lambda () (and (plist-get (etaf-youtube-state app) :video)
                                     (etaf-youtube-media-src app)))))
            (let ((runtime (etaf-runtime-for-buffer buffer)))
              (etaf-runtime-flush runtime)
              (with-current-buffer buffer
                (let ((orig-ml mode-line-format)
                      (normal-text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p "全屏" normal-text))
                  ;; Enter window fullscreen
                  (etaf-youtube-toggle-fullscreen app 'window)
                  (etaf-runtime-flush runtime)
                  (should (eq 'window (etaf-fullscreen-mode buffer)))
                  (should (null mode-line-format))
                  (let ((fs-text (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "↩ 退出" fs-text))
                    (should (string-match-p "真全屏 F" fs-text))
                    (should-not (string-match-p "← 返回" fs-text)))
                  ;; Upgrade to frame fullscreen
                  (etaf-youtube-toggle-fullscreen app 'frame)
                  (etaf-runtime-flush runtime)
                  (should (eq 'frame (etaf-fullscreen-mode buffer)))
                  ;; Exit restores mode-line and normal Watch header
                  (etaf-youtube-exit-fullscreen app)
                  (etaf-runtime-flush runtime)
                  (should-not (etaf-fullscreen-mode buffer))
                  (should (equal mode-line-format orig-ml))
                  (let ((after-text (buffer-substring-no-properties (point-min) (point-max))))
                    (should (string-match-p "← 返回" after-text)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'etaf-youtube-tests)
;;; etaf-youtube-tests.el ends here
