;;; -*- lexical-binding: t; -*-
;;; etaf-bili-gallery-tests.el --- Public gallery and asynchronous regressions

;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'cl-lib)
(require 'etaf-bili)
(require 'etaf-ui)

(defconst etaf-bili-gallery-tests--curl
  (expand-file-name "fixtures/cover-curl.py"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun etaf-bili-gallery-tests--rows ()
  "Return stable fixture videos, with no network-dependent covers."
  (cl-loop for index below 20 collect
           (list :bvid (format "BV%d" index) :title (format "视频 %d · Emacs 创作" index)
                 :author "创作者" :duration 120 :views "12000"
                 :date "2026-10-13" :cover "")))

(defmacro etaf-bili-gallery-tests--mounted (&rest body)
  "Mount an offline gallery for BODY and always release it."
  (declare (indent 0))
  `(let ((etaf-bili-client-factory
          (lambda () (lambda (_request callback)
                       (funcall callback (list :ok (etaf-bili-gallery-tests--rows)))))))
     (when noninteractive (set-frame-size (selected-frame) 120 40))
     (let ((buffer (etaf-bili-open)))
       (unwind-protect (with-current-buffer buffer ,@body)
         (etaf-bili-close)))))

(ert-deftest etaf-bili-gallery-tests-catalog-controls-and-scrolling ()
  "Cards, search, native scrolling and details are public UI targets."
  (etaf-bili-gallery-tests--mounted
    (let* ((runtime (etaf-runtime-for-buffer buffer))
           (card (etaf-host-ref-size runtime 'bili-card-0))
           (search (etaf-host-ref-size runtime 'bili-search)))
      (should card) (should search)
      (let ((shell-size (etaf-host-ref-size runtime 'bili-shell))
            (viewport (or (etaf-runtime-window-viewport runtime)
                          (etaf-runtime-viewport runtime))))
        (should (<= (car shell-size) (car viewport))))
      (etaf-bili-next)
      (let ((focused (etaf-focused-host-ref runtime)))
        (should (eq 'bili-card-1 focused)))
      (let ((offset (etaf-scroll-by runtime 'bili-gallery 3)))
        (should (= offset 3)))
      (let ((offset (etaf-scroll-to runtime 'bili-gallery 'end)))
        (should (> offset 3)))
      (etaf-runtime-flush runtime)
      (let ((last (etaf-host-ref-size runtime 'bili-card-19))) (should last))
      (etaf-scroll-to runtime 'bili-gallery 'start)
      (etaf-runtime-flush runtime)
      (let ((first (etaf-host-ref-size runtime 'bili-card-0))) (should first))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not (string-match-p "上一屏\\|下一屏" text)))
      (etaf-bili-previous)
      (let ((focused (etaf-focused-host-ref runtime)))
        (should (eq 'bili-card-0 focused)))
      (etaf-bili-details)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "视频详情" text)))
      (execute-kbd-macro (kbd "<escape>"))
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should-not (string-match-p "视频详情" text))))))

(ert-deftest etaf-bili-gallery-tests-search-editing-keeps-application-keys ()
  "Letters used as application commands remain text inside SearchField."
  (etaf-bili-gallery-tests--mounted
    (switch-to-buffer buffer)
    (execute-kbd-macro (kbd "/"))
    (let ((active (and (etaf-text-input-active-p) t))) (should active))
    (execute-kbd-macro (vconcat "Emacs g T j / 配置"))
    (execute-kbd-macro (kbd "RET"))
    (let ((active (and (etaf-text-input-active-p) t))
          (text (buffer-substring-no-properties (point-min) (point-max))))
      (should-not active)
      (should (string-match-p "Emacs g T j / 配置" text)))))

(ert-deftest etaf-bili-gallery-tests-empty-error-and-stale-results ()
  "Empty success clears old cards; a stale response cannot overwrite a new search."
  (let* ((callbacks nil)
         (client (lambda (request callback) (push (cons request callback) callbacks)))
         (session (etaf-bili-session-create :client client)))
    (etaf-bili-search session "旧搜索")
    (etaf-bili-search session "新搜索")
    (funcall (cdar callbacks) '(:ok nil))
    (funcall (cdr (cadr callbacks)) (list :ok (etaf-bili-gallery-tests--rows)))
    (let ((state (etaf-bili-session-state session)))
      (should-not (plist-get state :items))
      (should-not (plist-get state :error))
      (should (equal "搜索 新搜索 · 0 条" (plist-get state :status))))))

(ert-deftest etaf-bili-gallery-tests-latest-play-request-wins ()
  "A late previous-video URL cannot replace the most recently requested video."
  (let* ((pending nil) (received nil)
         (client (lambda (request callback)
                   (if (eq (plist-get request :op) :play)
                       (push callback pending)
                     (funcall callback (list :ok (etaf-bili-gallery-tests--rows))))))
         (session (etaf-bili-session-create :client client)))
    (etaf-bili-load-popular session)
    (etaf-bili-play-selected session (lambda (source) (push source received)))
    (etaf-bili-move session 1)
    (etaf-bili-play-selected session (lambda (source) (push source received)))
    (funcall (car pending) '(:ok (:title "新视频" :url "https://example.test/new")))
    (funcall (cadr pending) '(:ok (:title "旧视频" :url "https://example.test/old")))
    (should (equal '("新视频") (mapcar (lambda (source) (plist-get source :title)) received)))))

(ert-deftest etaf-bili-gallery-tests-close-ignores-pending-response ()
  "Killing the app releases its view and a late response cannot recreate it."
  (let* ((callback nil)
         (etaf-bili-client-factory
          (lambda () (lambda (_request done) (setq callback done))))
         (buffer (etaf-bili-open)))
    (kill-buffer buffer)
    (funcall callback (list :ok (etaf-bili-gallery-tests--rows)))
    (should-not (get-buffer "*Bili*"))))

(ert-deftest etaf-bili-gallery-tests-theme-preserves-frame-and-query ()
  "Switching palettes changes only the application and preserves search input."
  (let ((previous etaf-bili-theme-mode)
        (background (frame-parameter nil 'background-color))
        (decoration (frame-parameter nil 'undecorated)))
    (unwind-protect
        (etaf-bili-gallery-tests--mounted
          (etaf-bili-toggle-theme)
          (should (equal background (frame-parameter nil 'background-color)))
          (should (equal decoration (frame-parameter nil 'undecorated)))
          (let ((runtime (etaf-runtime-for-buffer buffer))
                (text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "创作者" text))
            (let ((gallery (etaf-host-ref-size runtime 'bili-gallery))) (should gallery))))
      (setq etaf-bili-theme-mode previous))))

(ert-deftest etaf-bili-gallery-tests-cover-cache-and-transfer-failure ()
  "Cover downloads return local files, reuse cache and clean failed transfers."
  (let* ((directory (make-temp-file "bili-covers-" t))
         (client (etaf-bili-make-client :state-directory directory))
         (etaf-bili-curl-program etaf-bili-gallery-tests--curl)
         result)
    (unwind-protect
        (progn
          (etaf-bili-client-call client '(:op :cover :url "https://i0.hdslb.com/a.svg")
                                 (lambda (reply) (setq result reply)))
          (let ((deadline (+ (float-time) 3)))
            (while (and (not result) (< (float-time) deadline)) (sleep-for 0.02)))
          (let ((file (plist-get result :ok)))
            (should (and (stringp file) (file-readable-p file)))
            (let ((etaf-bili-curl-program "/nonexistent/curl") cached)
              (etaf-bili-client-call client '(:op :cover :url "https://i0.hdslb.com/a.svg")
                                     (lambda (reply) (setq cached reply)))
              (should (equal file (plist-get cached :ok)))))
          (setq result nil)
          (etaf-bili-client-call client '(:op :cover :url "https://i0.hdslb.com/fail.svg")
                                 (lambda (reply) (setq result reply)))
          (let ((deadline (+ (float-time) 3)))
            (while (and (not result) (< (float-time) deadline)) (sleep-for 0.02)))
          (should (plist-get result :error))
          (should-not (seq-filter (lambda (name) (string-prefix-p ".cover-" name))
                                  (directory-files (expand-file-name "covers" directory)))))
      (delete-directory directory t))))

(provide 'etaf-bili-gallery-tests)
