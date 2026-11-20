;;; etaf-ncm-demo.el --- Runnable NetEase Cloud Music player demo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; M-x etaf-ncm-demo-open mounts the complete player in one buffer and drives
;; it from a scripted backend, so the demo runs without network, login or mpv:
;; browse the daily list, search, play, pause, skip, queue songs, change the
;; volume, follow the lyric and switch the panel and the palette.
;;
;; M-x etaf-ncm-demo-live opens the same player against the installed
;; `netease-music' backend instead, which is what `M-x etaf-ncm-open' does on
;; its own.  Both entries create at most one player and close the previous one.
;;
;; From a checkout with sibling provider repositories:
;;
;;   cd etaf-ncm
;;   emacs -Q -L ../ecss -L ../ebox -L ../etaf -L ../etaf-ui \
;;         -L . -l examples/etaf-ncm-demo.el -f etaf-ncm-demo-open

;;; Code:

(require 'cl-lib)
(require 'etaf-ncm)

(defconst etaf-ncm-demo--songs
  '(("晨雾里的站台" "林间电台" "清晨"   208000 "VIP")
    ("Sailing Home" "The Jetty Band" "Tidewater" 246000 nil)
    ("旧信封" "周未晚" "长夜短歌"   193000 nil)
    ("Neon Avenue" "Kiwi Fields" "City Light" 232000 "VIP")
    ("山雀" "白露" "山雀"   271000 nil)
    ("Slow Train" "Marlow" "Slow Train"   219000 nil)
    ("雨落青瓦" "陆离" "南风集"   186000 "VIP")
    ("Afterglow" "June Harbor" "Afterglow" 254000 nil))
  "Songs the scripted demo library plays, as (NAME ARTIST ALBUM MS BADGE).")

(defconst etaf-ncm-demo--lyric
  (concat "[00:00.00] 这是演示歌词\n"
          "[00:08.00] 拖动进度条是假的，歌词是真的\n"
          "[00:16.00] 每一句都跟着播放时间走\n"
          "[00:24.00] 按 l 可以换成播放队列\n"
          "[00:32.00] 按 T 换成浅色主题\n"
          "[00:40.00] 按 q 关掉这个播放器\n")
  "Scripted lyric of the demo, as raw LRC text.")

(defvar etaf-ncm-demo--elapsed 0
  "Playback position the scripted demo reports, in seconds.")

(defvar etaf-ncm-demo--state 'paused
  "Playback state the scripted demo reports.")

(defun etaf-ncm-demo--rows ()
  "Return the demo songs as library rows."
  (cl-loop for (name artist album ms badge) in etaf-ncm-demo--songs
           for index from 1
           collect (list :kind :song :id index :name name :subtitle artist
                         :meta album :badge badge
                         :right (format "%d:%02d" (/ ms 60000) (/ (% ms 60000) 1000)))))

(defun etaf-ncm-demo--client (request callback)
  "Answer REQUEST on CALLBACK from the scripted demo library."
  (let ((op (plist-get request :op)))
    (pcase op
      (:status
       (setq etaf-ncm-demo--elapsed (+ etaf-ncm-demo--elapsed 1))
       (funcall callback
                (list :ok (list :ok t
                                :conclusion "正在播放：晨雾里的站台 - 林间电台"
                                :title "晨雾里的站台" :artist "林间电台" :song_id "1"
                                :state etaf-ncm-demo--state
                                :queue_pos (format "1/%d" (length etaf-ncm-demo--songs))
                                :elapsed (number-to-string etaf-ncm-demo--elapsed)
                                :duration "208" :volume "55" :repeat "false"
                                :shuffle "false" :source "demo"
                                :as_of "2026-01-01T00:00:00+0800"))))
      (:toggle
       (setq etaf-ncm-demo--state (if (eq etaf-ncm-demo--state 'playing) 'paused 'playing))
       (funcall callback (list :ok (list :ok t))))
      (:queue
       (funcall callback
                (list :ok (list :count (number-to-string (length etaf-ncm-demo--songs))
                                :pos "1"
                                :songs (cl-loop for (name artist album ms _badge) in etaf-ncm-demo--songs
                                                for index from 1
                                                collect (list :id index :name name :artist artist
                                                              :album album :ms ms :vip nil))))))
      (:session
       (funcall callback (list :ok (list :loggedIn t :uid 0 :nick "演示听众" :vip 0))))
      (:lyric
       (funcall callback (list :ok (list :id (plist-get request :id)
                                         :lyric etaf-ncm-demo--lyric))))
      (:browse
       (funcall callback (list :ok (list :count (length etaf-ncm-demo--songs)
                                         :songs (cl-loop for (name artist album ms vip) in etaf-ncm-demo--songs
                                                         for index from 1
                                                         collect (list :id index :name name
                                                                       :artist artist :album album
                                                                       :ms ms :vip (and vip t)))))))
      (:search
       (let* ((keyword (regexp-quote (or (plist-get request :keyword) "")))
              (matches (cl-loop for (name artist album ms vip) in etaf-ncm-demo--songs
                                for index from 1
                                when (or (string-match-p keyword name)
                                         (string-match-p keyword artist))
                                collect (list :id index :name name :artist artist
                                              :album album :ms ms :vip (and vip t)))))
         (funcall callback (list :ok (list :kw (plist-get request :keyword)
                                           :count (length matches)
                                           :songs matches)))))
      (_ (funcall callback (list :ok (list :ok t)))))))

;;;###autoload
(defun etaf-ncm-demo-open ()
  "Open the player on a scripted library that needs no backend."
  (interactive)
  (let ((etaf-ncm-client-factory (lambda () #'etaf-ncm-demo--client)))
    (setq etaf-ncm-demo--elapsed 0
          etaf-ncm-demo--state 'playing)
    (etaf-ncm-close)
    (etaf-ncm-open)))

;;;###autoload
(defun etaf-ncm-demo-live ()
  "Open the player on the installed `netease-music' backend."
  (interactive)
  (etaf-ncm-close)
  (etaf-ncm-open))

(provide 'etaf-ncm-demo)
;;; etaf-ncm-demo.el ends here
