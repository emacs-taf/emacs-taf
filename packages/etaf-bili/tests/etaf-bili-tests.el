;;; etaf-bili-tests.el --- Public acceptance scenarios -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Offline scenarios for the client.  The fake backend answers through
;; `etaf-bili-client-factory''s injection point, so no scenario touches the
;; network: the model's load/move/play flows run against scripted replies,
;; and the two pure contracts (WBI signing and response parsing) are asserted
;; on fixed inputs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'etaf-bili)

(defvar etaf-bili-tests--requests nil
  "Requests the fake backend received, newest first.")

(defvar etaf-bili-tests--script nil
  "Alist of `:op' symbol to reply plist the fake backend answers with.")

(defun etaf-bili-tests--fake (request callback)
  "Fake backend: record REQUEST and answer from the scripted table."
  (push request etaf-bili-tests--requests)
  (funcall callback
           (or (cdr (assq (plist-get request :op) etaf-bili-tests--script))
               (list :error "unscripted request"))))

(defun etaf-bili-tests--row (title)
  "Return a scripted row plist titled TITLE."
  (list :bvid "BV1test" :aid 1 :title title :author "UP 主"
        :duration 61 :views "1.2万" :date "2026-10-13" :cover ""))

(defun etaf-bili-tests--session ()
  "Return a session wired to the fake backend."
  (etaf-bili-session-create :client #'etaf-bili-tests--fake))

(ert-deftest etaf-bili-tests-popular-loads-rows-and-status ()
  "Loading the popular feed replaces the rows and reports the count."
  (let ((etaf-bili-tests--requests nil)
        (etaf-bili-tests--script
         '((:popular :ok ((:bvid "BV1" :title "第一条")
                          (:bvid "BV2" :title "第二条"))))))
    (let* ((session (etaf-bili-tests--session))
           (state (progn (etaf-bili-load-popular session)
                         (etaf-bili-session-state session))))
      (should (= 2 (length (plist-get state :items))))
      (should (equal 'popular (plist-get state :mode)))
      (should (equal "热门 · 2 条" (plist-get state :status)))
      (should-not (plist-get state :loading))
      (should (equal "第一条" (plist-get (etaf-bili-selected-row session) :title)))
      (should (eq :popular (plist-get (car etaf-bili-tests--requests) :op))))))

(ert-deftest etaf-bili-tests-search-carries-keyword-and-replaces-rows ()
  "Searching sends the keyword and shows the reply; blank input is ignored."
  (let ((etaf-bili-tests--requests nil)
        (etaf-bili-tests--script
         '((:search :ok ((:bvid "BV9" :title "结果一"))))))
    (let* ((session (etaf-bili-tests--session))
           (_ (etaf-bili-search session "Emacs 配置"))
           (request (car etaf-bili-tests--requests))
           (state (etaf-bili-session-state session)))
      (should (eq :search (plist-get request :op)))
      (should (equal "Emacs 配置" (plist-get request :keyword)))
      (should (equal "搜索 Emacs 配置 · 1 条" (plist-get state :status)))
      (should (equal "结果一" (plist-get (etaf-bili-selected-row session) :title)))
      ;; A blank keyword neither replaces the rows nor sends a request.
      (let ((before (length etaf-bili-tests--requests)))
        (etaf-bili-search session "   ")
        (should (= before (length etaf-bili-tests--requests)))
        (should (equal "结果一"
                       (plist-get (etaf-bili-selected-row session) :title)))))))

(ert-deftest etaf-bili-tests-selection-moves-and-clamps ()
  "Selection moves by one and clamps at both ends of the list."
  (let ((etaf-bili-tests--requests nil)
        (etaf-bili-tests--script
         '((:popular :ok ((:bvid "BV1" :title "一")
                          (:bvid "BV2" :title "二")
                          (:bvid "BV3" :title "三"))))))
    (let ((session (etaf-bili-tests--session)))
      (etaf-bili-load-popular session)
      (etaf-bili-move session 1)
      (should (= 1 (plist-get (etaf-bili-session-state session) :selected)))
      (etaf-bili-move session 5)
      (should (= 2 (plist-get (etaf-bili-session-state session) :selected)))
      (etaf-bili-move session -9)
      (should (= 0 (plist-get (etaf-bili-session-state session) :selected)))
      (should (equal "一" (plist-get (etaf-bili-selected-row session) :title))))))

(ert-deftest etaf-bili-tests-play-selected-delivers-stream-source ()
  "Playing the selected row hands the stream source to the caller."
  (let ((etaf-bili-tests--requests nil)
        (etaf-bili-tests--script
         '((:popular :ok ((:bvid "BV1" :title "视频")))
           (:play :ok (:url "https://cdn.example/clip.mp4"
                            :bvid "BV1"
                            :title "视频"
                            :duration 61
                            :headers (("Referer" . "https://www.bilibili.com"))))))
        received)
    (let ((session (etaf-bili-tests--session)))
      (etaf-bili-load-popular session)
      (etaf-bili-play-selected session (lambda (source) (setq received source)))
      (should (equal "https://cdn.example/clip.mp4" (plist-get received :url)))
      (should (equal "https://www.bilibili.com"
                     (cdr (assoc "Referer" (plist-get received :headers)))))
      (should (equal '(:op :play :bvid "BV1")
                     (car etaf-bili-tests--requests)))
      (should (equal "播放：视频" (plist-get (etaf-bili-session-state session) :status)))
      ;; The resolved stream is kept: pressing the same card again must not
      ;; ask the site a second time.
      (let ((before (length etaf-bili-tests--requests))
            (again nil))
        (etaf-bili-play-selected session (lambda (source) (setq again source)))
        (should (equal "https://cdn.example/clip.mp4" (plist-get again :url)))
        (should (= before (length etaf-bili-tests--requests)))))))

(ert-deftest etaf-bili-tests-play-failure-only-changes-status ()
  "A failed stream lookup reports on the status line and plays nothing."
  (let ((etaf-bili-tests--requests nil)
        (etaf-bili-tests--script
         '((:popular :ok ((:bvid "BV1" :title "视频")))
           (:play :error "Bilibili error -404: 啥都木有")))
        called)
    (let ((session (etaf-bili-tests--session)))
      (etaf-bili-load-popular session)
      (etaf-bili-play-selected session (lambda (_source) (setq called t)))
      (should-not called)
      (should (equal "播放失败：Bilibili error -404: 啥都木有"
                     (plist-get (etaf-bili-session-state session) :status))))))

(ert-deftest etaf-bili-tests-wbi-query-signs-encode-uri-component ()
  "WBI signing sorts keys, encodes like encodeURIComponent, and appends w_rid."
  (let ((query (etaf-bili-wbi-query
                '(("search_type" . "video") ("keyword" . "Emacs 配置") ("page" . "1"))
                "0123456789abcdef0123456789abcdef"
                "1789000000")))
    (should (equal
             "keyword=Emacs%20%E9%85%8D%E7%BD%AE&page=1&search_type=video&wts=1789000000&w_rid=ed67f5c8870ac325a3443bbe94a655db"
             query)))
  (should-error (etaf-bili-wbi-query '(("page" . "1")) nil "1")
                :type 'etaf-bili-error))

(ert-deftest etaf-bili-tests-parse-videos-normalizes-rows ()
  "Response parsing cleans titles, converts clocks and reads both list shapes."
  (let* ((payload (json-parse-string
                   (concat "{\"list\":[{\"bvid\":\"BV1\",\"aid\":42,"
                           "\"title\":\"【标题】<em class=\\\"keyword\\\">Emacs</em>\","
                           "\"owner\":{\"name\":\"UP\"},\"stat\":{\"view\":123456},"
                           "\"duration\":754,\"pubdate\":1791808200}]}")
                   :object-type 'alist :array-type 'list))
         (rows (etaf-bili-parse-videos payload)))
    (should (= 1 (length rows)))
    (let ((row (car rows)))
      (should (equal "【标题】Emacs" (plist-get row :title)))
      (should (equal "UP" (plist-get row :author)))
      (should (= 754 (plist-get row :duration)))
      (should (equal "123456" (plist-get row :views)))
      (should (equal "2026-10-12" (plist-get row :date)))))
  ;; The search shape carries a `result' array, `author' and a string clock.
  (let* ((payload (json-parse-string
                   (concat "{\"result\":[{\"bvid\":\"BV2\",\"title\":\"结果\","
                           "\"author\":\"作者\",\"duration\":\"12:34\",\"play\":\"1.2万\"}]}")
                   :object-type 'alist :array-type 'list))
         (rows (etaf-bili-parse-videos payload)))
    (should (= 1 (length rows)))
    (let ((row (car rows)))
      (should (equal "作者" (plist-get row :author)))
      (should (= 754 (plist-get row :duration)))
      (should (equal "1.2万" (plist-get row :views))))))

(provide 'etaf-bili-tests)
;;; etaf-bili-tests.el ends here

;;; Account commands

(defconst etaf-bili-tests--account-backend
  (expand-file-name "fixtures/fake-account-backend.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Stand-in for the bundled account backend in the account scenarios.")

(defconst etaf-bili-tests--account-scan-backend
  (expand-file-name "fixtures/fake-account-backend-scan.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Stand-in backend that only confirms after the code was scanned.")

(defun etaf-bili-tests--account-wait (predicate &optional seconds)
  "Wait until PREDICATE is non-nil for at most SECONDS."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (< (float-time) deadline) (not (funcall predicate)))
      (accept-process-output nil 0.02)
      (sleep-for 0.01))
    (funcall predicate)))

(defun etaf-bili-tests--login-state (session)
  "Return the sign-in state the client publishes for SESSION."
  (plist-get (etaf-bili-session-state session) :login))

(ert-deftest etaf-bili-tests-login-overlays-the-code-and-finishes-on-confirmation ()
  "Signing in overlays the code on the client and closes when confirmed.
The stand-in backend answers the start and poll commands the real one uses;
the session's sign-in state carries the painted code and the signed-in name."
  (let ((etaf-bili-backend-command (list etaf-bili-tests--account-backend))
        (etaf-bili-login-poll-interval 0.05))
    (let ((session (etaf-bili-session-create)))
      (unwind-protect
          (progn
            (etaf-bili-login session)
            (should (plist-get (etaf-bili-tests--login-state session) :open))
            (should (etaf-bili-tests--account-wait
                     (lambda ()
                       (string-match-p "█"
                                       (or (plist-get (etaf-bili-tests--login-state session) :qr)
                                           "")))))
            (should (etaf-bili-tests--account-wait
                     (lambda ()
                       (not (plist-get (etaf-bili-tests--login-state session) :open)))))
            (should (equal "测试用户"
                           (plist-get (etaf-bili-session-state session) :account))))
        (etaf-bili-account-cancel session)))))

(ert-deftest etaf-bili-tests-login-keeps-polling-until-the-phone-confirms ()
  "A scanned code keeps being polled until the backend confirms it.
The stand-in advances waiting, scanned, then confirmed, so a client that
looks once and stops leaves the panel open with the code still showing."
  (let* ((counter (make-temp-file "bili-scan"))
         (etaf-bili-backend-command (list etaf-bili-tests--account-scan-backend))
         (etaf-bili-login-poll-interval 0.05)
         (process-environment (cons (format "BILI_FAKE_COUNTER=%s" counter)
                                    process-environment)))
    (unwind-protect
        (let ((session (etaf-bili-session-create)))
          (unwind-protect
              (progn
                (etaf-bili-login session)
                (should (etaf-bili-tests--account-wait
                         (lambda ()
                           (not (plist-get (etaf-bili-tests--login-state session) :open)))))
                (should (>= (string-to-number
                             (with-temp-buffer
                               (insert-file-contents counter)
                               (buffer-string)))
                            3))
                (should (equal "扫码用户"
                               (plist-get (etaf-bili-session-state session) :account))))
            (etaf-bili-account-cancel session)))
      (delete-file counter))))

(ert-deftest etaf-bili-tests-logout-calls-the-backend-after-confirmation ()
  "Signing out asks first, then lets the backend clear the cookies."
  (let* ((log (make-temp-file "etaf-bili-account-"))
         (etaf-bili-backend-command (list etaf-bili-tests--account-backend))
         (process-environment (cons (format "BILI_FAKE_LOG=%s" log) process-environment)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (etaf-bili-logout))
          (should (etaf-bili-tests--account-wait
                   (lambda ()
                     (with-temp-buffer
                       (insert-file-contents log)
                       (string-match-p "logout" (buffer-string)))))))
      (delete-file log))))

(ert-deftest etaf-bili-tests-view-mounts-in-a-host-buffer ()
  "A host mounts the View, keeps the client's keys and reuses its session.
The session is adopted by the buffer that mounts it and the popular feed loads
on the first mount, so mounting the same session again shows what was loaded
instead of fetching it again."
  (let ((etaf-bili-tests--requests nil)
        (etaf-bili-tests--script
         '((:popular :ok ((:bvid "BV1" :title "宿主里的第一条"))))))
    (let* ((session (etaf-bili-tests--session))
           (buffer (generate-new-buffer " *etaf-bili host*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (etaf-mount buffer (etaf-bili-view session))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "宿主里的第一条" text)))
            (should (equal "热门 · 1 条"
                           (plist-get (etaf-bili-session-state session) :status)))
            ;; The client's own key reaches the session the host mounted.
            (execute-kbd-macro (kbd "g"))
            (should (equal 2 (length etaf-bili-tests--requests)))
            ;; Unmounting keeps the library, so mounting the same session again
            ;; shows what was loaded instead of fetching it again.
            (etaf-unmount (etaf-runtime-for-buffer buffer))
            (etaf-mount buffer (etaf-bili-view session))
            (should (equal 2 (length etaf-bili-tests--requests)))
            (should (string-match-p "宿主里的第一条"
                                    (buffer-substring-no-properties (point-min) (point-max)))))
        (when-let* ((runtime (etaf-runtime-for-buffer buffer)))
          (etaf-unmount runtime))
        (kill-buffer buffer)))))
