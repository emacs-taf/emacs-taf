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
  "Return ARGV's skill arguments, without the program and --json."
  (cl-remove-if (lambda (argument) (equal argument "--json"))
                (cdr (member "youtube" argv))))

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
                                        log fetcher async)
  "Create a test session over FIXTURES.
LOG receives the skill calls; FETCHER defaults to the pixel copy; ASYNC uses
a delayed runner instead of the fixture runner."
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
     :store :none)))

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
    (etaf-youtube-select app 1)
    (should (= 1 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-select app -1)
    (should (= 0 (plist-get (etaf-youtube-state app) :selected)))
    (etaf-youtube-activate app)
    (should (etaf-youtube-tests--wait
             (lambda () (eq 'watch (plist-get (etaf-youtube-state app) :view)))))
    (should (member '("video" "v1") (etaf-youtube-tests--calls log)))))

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

(ert-deftest etaf-youtube-thumbnails-load-through-the-injected-fetcher ()
  "Requesting a thumbnail stores a descriptor and bumps the version."
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
         (etaf-youtube-program etaf-youtube-tests--fake-skill)
         (result nil))
    (etaf-youtube-service-call service '("check")
                               (lambda (value) (setq result value))
                               :process-test)
    (should (etaf-youtube-tests--wait (lambda () result)))
    (should (eq 'ok (plist-get result :status)))
    (should (equal "Process Runner" (plist-get (plist-get result :value) :name)))
    (etaf-youtube-service-close service)))

(ert-deftest etaf-youtube-thumbnails-strip-signed-query ()
  "Signed YouTube thumbnail tokens are dropped before downloading.
The token makes the CDN answer with AVIF while the unsigned URL serves a
JPEG, so the fetcher must receive the unsigned address while the cache still
keys the original URL."
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

(provide 'etaf-youtube-tests)
;;; etaf-youtube-tests.el ends here
