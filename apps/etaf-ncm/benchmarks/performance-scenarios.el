;;; performance-scenarios.el --- Music library switching -*- lexical-binding: t; -*-

;;; Commentary:
;; Cached sidebar navigation, including native publication and redisplay.
;; Run with the workspace scripts/performance.py driver.  No network/player.

;;; Code:
(require 'etaf-ncm)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-ncm-benchmark--fixture (_mode)
  "Mount a deterministic player and switch between two warmed libraries."
  (let* ((etaf-ncm-buffer-name " *ncm-switch-benchmark*")
         (etaf-ncm-status-interval 3600)
         (display-buffer-overriding-action '((display-buffer-same-window)))
         (songs (cl-loop for i from 1 to 60
                         collect (list :id i :name (format "曲目 %d" i)
                                       :artist "歌手" :album "专辑" :ms 180000)))
         (warm t)
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (pcase (plist-get request :op)
                           (:browse
                            (when warm
                              (funcall callback
                                       (list :ok (list :songs (if (eq (plist-get request :resource) :daily)
                                                                  songs (reverse songs)) :total 60)))))
                           (:status (funcall callback '(:ok (:state "stopped"))))
                           (_ (funcall callback '(:ok nil)))))))
         buffer runtime (section :daily))
    (etaf-ncm-open app)
    (setq buffer (current-buffer) runtime (etaf-runtime-for-buffer buffer))
    (etaf-ncm-locate app :liked)
    (etaf-ncm-locate app :daily)
    (etaf-runtime-flush runtime)
    (setq warm nil)
    (list :buffer buffer
          :environment (lambda () (list :network :false :rows 60 :cached t))
          :ready (lambda () t)
          :prepare (lambda () (setq section (if (eq section :daily) :liked :daily)))
          :invoke (lambda (_sample)
                    (etaf-ncm-locate app section)
                    (etaf-runtime-flush runtime))
          :verify (lambda () (and (eq section (plist-get (etaf-ncm-state app) :section))
                                   (= 60 (plist-get (etaf-ncm-state app) :rows-total))))
          :outcome (lambda () (list :section (symbol-name section)))
          :cleanup (lambda () (when (buffer-live-p buffer)
                                (with-current-buffer buffer (etaf-ncm-close)))))))

(taf-benchmark-register
 "ncm.sidebar.cached" :version 1 :modes '(batch gui) :isolation 'series
 :required-providers '(etaf) :budget-ms 100 :impact 'local
 :description "Cached music library switch through native publication"
 :setup #'etaf-ncm-benchmark--fixture)

(defun etaf-ncm-benchmark--open-fixture (cached)
  "Return a fixture whose measured action mounts the player.
CACHED pre-fills the nine sidebar caches before the open, so the two
scenarios separate a cold first mount from a cache-warm reopen.  Fresh
isolation gives every sample its own model; replies are synchronous and
offline, so the measured open includes mount, first publication and the
first redisplay flush."
  (let* ((etaf-ncm-status-interval 3600)
         (etaf-ncm-prefetch-libraries nil)
         (etaf-ncm-buffer-name " *ncm-open-benchmark*")
         (display-buffer-overriding-action '((display-buffer-same-window)))
         (sections '(:daily :fm :liked :playlists :albums :artists :charts :podcasts :recent))
         (backend (etaf-ncm-benchmark-backend))
         app buffer runtime)
    (lambda (_mode)
      (set-frame-size nil 150 45)
      (delete-other-windows)
      (setq app (etaf-ncm-create :client (plist-get backend :client)))
      (setq buffer (get-buffer-create etaf-ncm-buffer-name))
      ;; The player hides its mode line; hiding it before the measured open
      ;; keeps the window body height from changing inside the timed action.
      (with-current-buffer buffer (setq-local mode-line-format nil))
      (when cached
        ;; Warm every sidebar in the model's own cache before mounting; the
        ;; replies are synchronous, so this is a real cache fill, not a stub.
        (dolist (section sections) (etaf-ncm-locate app section)))
      (list
       :buffer buffer
       :environment (lambda () (list :network :false :songs 180
                                     :cached (if cached t :false)
                                     :libraries (if cached (length sections) 0)))
       :ready (lambda () t)
       :invoke (lambda (_sample)
                 (let ((etaf-ncm-buffer-name (buffer-name buffer)))
                   (setq buffer (etaf-ncm-open app)))
                 (setq runtime (etaf-runtime-for-buffer buffer))
                 (etaf-runtime-flush runtime))
       :verify (lambda ()
                 (and (buffer-live-p buffer)
                      runtime (etaf-runtime-for-buffer buffer)
                      (eq (plist-get app :buffer) buffer)
                      (> (or (plist-get (etaf-ncm-state app) :rows-total) 0) 0)))
       :outcome (lambda () (list :cached (if cached t :false)
                                 :mounted (and (buffer-live-p buffer)
                                               (etaf-runtime-for-buffer buffer)
                                               t)))
       :cleanup (lambda ()
                  (when (buffer-live-p buffer)
                    (let ((etaf-ncm-buffer-name (buffer-name buffer)))
                      (with-current-buffer buffer (etaf-ncm-close)))))))))

(taf-benchmark-register
 "ncm.app.open.cold" :version 1 :modes '(gui) :isolation 'fresh
 :required-providers '(etaf) :budget-ms 500 :impact 'local
 :description "Mount and first-paint the player with empty sidebar caches"
 :setup (lambda (mode) (funcall (etaf-ncm-benchmark--open-fixture nil) mode)))

(taf-benchmark-register
 "ncm.app.open.cached" :version 1 :modes '(gui) :isolation 'fresh
 :required-providers '(etaf) :budget-ms 500 :impact 'local
 :description "Reopen the player with all nine sidebars cached"
 :setup (lambda (mode) (funcall (etaf-ncm-benchmark--open-fixture t) mode)))

(load (expand-file-name "interaction-scenarios.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

;;; performance-scenarios.el ends here
