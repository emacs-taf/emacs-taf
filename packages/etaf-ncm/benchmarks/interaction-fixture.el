;;; interaction-fixture.el --- Stateful offline interaction workload -*- lexical-binding: t; -*-

;;; Commentary:
;; No account, network, player or filesystem mutations. Replies use the real
;; service's plist protocol and reflect commands, so a next-track or seek test
;; cannot accidentally measure a constant canned status. Read/reply phases can
;; be held independently to measure input and reconciliation separately.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'etaf-ncm)

(defun etaf-ncm-benchmark-songs (count &optional offset)
  "Build COUNT varied metadata records beginning at OFFSET."
  (let ((titles '("晨雾里的站台" "Sailing Home" "旧信封（现场版）" "Neon Avenue"
                  "一首很长的歌名：风从故乡来" "Slow Train / Acoustic" "雨落青瓦" "Afterglow")))
    (cl-loop for i from 1 to count for id = (+ i (or offset 0))
             collect (list :id id :name (format "%s %d" (nth (% id 8) titles) id)
                           :artist (if (= (% id 5) 0) "June Harbor & 林间电台" "歌手")
                           :album (if (= (% id 4) 0) "" "长夜短歌 / Live")
                           :ms (+ 180000 (* (% id 5) 13000)) :vip (zerop (% id 3))
                           :creator "演示听众" :count (+ 30 i) :size (+ 8 (% id 6))
                           :albums (+ 1 (% id 20)) :dj "电台" :episodes (+ 10 i) :freq "每日更新"))))

(defun etaf-ncm-benchmark-backend ()
  "Return a fresh offline backend state with a callable :client."
  (let* ((songs (etaf-ncm-benchmark-songs 180))
         (state (list :songs songs :queue (seq-take songs 80) :pos 2 :elapsed 42
                      :state "paused" :volume 55 :shuffle nil :repeat nil
                      :likes '(2) :downloads nil :hold nil :pending nil :requests nil :client nil)))
    (setf (plist-get state :client)
          (lambda (request callback)
            (push request (plist-get state :requests))
            (let ((reply (etaf-ncm-benchmark-reply state request)))
              (if (memq (plist-get request :op) (plist-get state :hold))
                  (setf (plist-get state :pending)
                        (append (plist-get state :pending)
                                (list (list (plist-get request :op) callback reply))))
                (funcall callback (list :ok reply))))))
    state))

(defun etaf-ncm-benchmark-reply (state request)
  "Apply REQUEST to STATE and produce the documented backend reply."
  (let* ((op (plist-get request :op))
         (songs (plist-get state :songs))
         (queue (plist-get state :queue))
         (pos (plist-get state :pos))
         (song (nth (1- pos) queue)))
    (pcase op
      (:browse
       (let* ((resource (plist-get request :resource))
              (n (pcase resource (:daily 30) (:fm 30) (:liked 179) (:recent 100)
                        (:playlists 36) (:albums 4) (:artists 68) (:charts 63) (:podcasts 29)))
              (key (if (memq resource '(:daily :fm :liked :recent)) :songs resource)))
         (list key (seq-take (if (eq resource :fm) (reverse songs) songs) (or n 0)) :total (or n 0))))
      (:search (list :songs (seq-take (reverse songs) 17) :total 17))
      (:status
       (list :state (plist-get state :state) :song_id (plist-get song :id)
             :title (plist-get song :name) :artist (plist-get song :artist)
             :elapsed (plist-get state :elapsed) :duration (/ (plist-get song :ms) 1000.0)
             :queue_pos (format "%d/%d" pos (length queue)) :volume (plist-get state :volume)
             :shuffle (if (plist-get state :shuffle) "true" "false")
             :repeat (if (plist-get state :repeat) "true" "false") :source "offline-benchmark"))
      (:queue (list :songs queue :count (length queue) :pos pos))
      (:session '(:loggedIn t :uid 0 :nick "演示听众" :vip 0))
      (:liked-ids (list :ids (plist-get state :likes)))
      (:downloads (list :downloads (plist-get state :downloads)))
      (:lyric
       (list :id (plist-get request :id)
             :lyric (mapconcat (lambda (i) (format "[%02d:%02d.00] 第 %d 行歌词，风从故乡来" (/ (* i 2) 60) (% (* i 2) 60) i))
                               (number-sequence 0 89) "\n")))
      (:play
       (let* ((ids (or (plist-get request :ids)
                       (let ((id (plist-get (plist-get request :target) :id)))
                         (and id (list id)))
                       (mapcar (lambda (s) (plist-get s :id)) (seq-take songs 30))))
              (next (delq nil (mapcar (lambda (id) (seq-find (lambda (s) (equal id (plist-get s :id))) songs)) ids))))
         (setf (plist-get state :queue) next
               (plist-get state :pos) (or (plist-get request :start) 1)
               (plist-get state :elapsed) 0
               (plist-get state :state) "playing")) t)
      ((or :next :previous :jump)
       (setf (plist-get state :pos)
             (if (eq op :jump) (plist-get request :index)
               (1+ (mod (+ (1- pos) (if (eq op :next) 1 -1)) (length queue))))
             (plist-get state :elapsed) 0) t)
      (:toggle (setf (plist-get state :state) (if (equal (plist-get state :state) "playing") "paused" "playing")) t)
      (:stop (setf (plist-get state :state) "stopped") t)
      (:volume (setf (plist-get state :volume) (plist-get request :value)) t)
      (:seek (setf (plist-get state :elapsed) (max 0 (+ (plist-get state :elapsed) (plist-get request :seconds)))) t)
      (:shuffle (setf (plist-get state :shuffle) (plist-get request :on)) t)
      (:repeat (setf (plist-get state :repeat) (plist-get request :on)) t)
      ;; The app's like/unlike commands target the currently playing song and
      ;; carry no id of their own; mirror the service and use the queue song.
      (:like (cl-pushnew (plist-get song :id) (plist-get state :likes)) t)
      (:unlike (setf (plist-get state :likes) (remove (plist-get song :id) (plist-get state :likes))) t)
      (:add (setf (plist-get state :queue) (append queue (list (seq-find (lambda (s) (equal (plist-get request :id) (plist-get s :id))) songs)))) t)
      (:download
       (let ((entry (list :id (plist-get request :id) :name "离线验证" :artist "演示"
                          :file "/offline-fixture/not-an-actual-file.flac" :level "lossless" :br 900000 :bytes 1000)))
         (push entry (plist-get state :downloads)) entry))
      (_ (error "Unimplemented benchmark request: %S" request)))))

(defun etaf-ncm-benchmark-deliver (state)
  "Deliver every pending reply in STATE; callbacks may issue follow-up reads."
  (let ((pending (plist-get state :pending)))
    (setf (plist-get state :pending) nil)
    (dolist (entry pending)
      (funcall (nth 1 entry) (list :ok (nth 2 entry))))))

(provide 'etaf-ncm-interaction-fixture)
;;; interaction-fixture.el ends here
