;;; etaf-ncm-service.el --- NetEase Cloud Music backend client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The player does not re-implement the NetEase protocol.  It drives the backend
;; bundled under the package's `backends/' through its two entry points:
;;
;;   node <backend>/scripts/netease-api.mjs COMMAND ...   reading API data
;;   bash <backend>/scripts/netease-music.sh COMMAND ...  playback and state
;;
;; Both print JSON.  Requests are plists such as (:op :browse :resource :daily)
;; and every call is asynchronous: CALLBACK runs later in the Emacs event loop
;; with (:ok DATA) or (:error MESSAGE :hint HINT).  Nothing here blocks, so the
;; interface keeps repainting while a request is in flight.
;;
;; Tests replace the transport by binding `etaf-ncm-client-factory' to a
;; function returning a fake client, so no scenario needs the network, mpv or a
;; login.  `etaf-ncm-parse-lyric' is transport independent and directly tested.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(define-error 'etaf-ncm-error "NetEase Cloud Music player error")

(defcustom etaf-ncm-backend-directory
  (expand-file-name "backends/netease"
                    (file-name-directory (or (locate-library "etaf-ncm")
                                             load-file-name
                                             buffer-file-name)))
  "Directory holding this package's NetEase backend.
`etaf-ncm-make-client' uses it to locate `scripts/netease-api.mjs' and
`scripts/netease-music.sh'.  The backend ships inside the package; point it
elsewhere only to try a modified copy."
  :type 'directory
  :group 'etaf-ncm)

(defcustom etaf-ncm-state-directory
  (expand-file-name "netease-music"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Directory holding the backend's state files.
The queue panel reads the documented `queue.json' track list from it; the
playback truth for the current index still comes from the backend command.
The client passes it to the backend as `NETEASE_MUSIC_STATE_DIR'."
  :type 'directory
  :group 'etaf-ncm)

(defcustom etaf-ncm-node-program "node"
  "Node executable used to run the backend's API client."
  :type 'string
  :group 'etaf-ncm)

(defcustom etaf-ncm-request-timeout 30
  "Seconds before a backend request is abandoned.
The timer kills the child process, so a hung `mpv' interaction cannot pin a
pending callback forever.  Callers see (:error MESSAGE)."
  :type 'number
  :group 'etaf-ncm)

(defvar etaf-ncm-client-factory nil
  "Function returning the backend client used by new players.
It is called with no arguments and must return a client built by
`etaf-ncm-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-ncm-client-call' documents.  Nil selects the default subprocess client;
tests bind this to a fake client.")

(cl-defstruct (etaf-ncm--client (:constructor etaf-ncm--client-create))
  "Backend client that runs the bundled backend as child processes."
  backend-directory state-directory node-program timeout (pending nil))

(cl-defstruct (etaf-ncm--pending (:constructor etaf-ncm--pending-create))
  "One in-flight backend request."
  process timer cancelled stdout stderr)

(cl-defun etaf-ncm-make-client (&key backend-directory state-directory node-program timeout)
  "Create a client that runs the bundled backend as child processes.
BACKEND-DIRECTORY, STATE-DIRECTORY, NODE-PROGRAM and TIMEOUT default to
`etaf-ncm-backend-directory', `etaf-ncm-state-directory',
`etaf-ncm-node-program' and `etaf-ncm-request-timeout'."
  (etaf-ncm--client-create
   :backend-directory (or backend-directory etaf-ncm-backend-directory)
   :state-directory (or state-directory etaf-ncm-state-directory)
   :node-program (or node-program etaf-ncm-node-program)
   :timeout (or timeout etaf-ncm-request-timeout)))

(defun etaf-ncm-client-call (client request callback)
  "Send REQUEST through CLIENT and deliver the reply to CALLBACK.
CLIENT is a client from `etaf-ncm-make-client' or a function of two arguments
(REQUEST CALLBACK), which is how tests inject a fake.

REQUEST is a plist whose `:op' selects one backend operation:

  :browse       (:op :browse :resource daily)  read one library list
  :search       (:op :search :keyword \"陈粒\" :scope song)
  :lyric        (:op :lyric :id 5231190)       fetch LRC text
  :session      (:op :session)                 account of the stored login
  :status       (:op :status)                  playback truth from mpv
  :queue        (:op :queue)                   queue count, index and tracks
  :play         (:op :play :target (:kind chart :id 19723756))
                Optional :ids (ID...) and :start N play the loaded order;
                N is 1-based. This uses play-ids instead of refetching a list.
  :add          (:op :add :id 5231190)         append one song to the queue
  :jump         (:op :jump :index 12)          play queue entry by index
  :volume       (:op :volume :value 60)        read the volume when VALUE is nil
  :seek         (:op :seek :seconds -10)       relative seek
  :like :unlike
  :liked-ids    (:op :liked-ids)               ids of every liked song
  :shuffle      (:op :shuffle :on t)
  :repeat       (:op :repeat :on nil)
  :queue-save   (:op :queue-save :name \"晚上\")
  :queue-load   (:op :queue-load :name \"晚上\")
  :cover        (:op :cover :id 5231190 :file PATH)
                download the song's cover art to PATH and reply with the
                saved :file; only requested for songs with a cover URL

`:timeout SECONDS' on any request replaces the client's own request timeout;
signing in needs it because a NetEase security check waits for a phone.

CALLBACK receives exactly one of (:ok DATA), where DATA is the decoded JSON
plist, or (:error MESSAGE :hint HINT) when the command failed, timed out or
returned a backend error.  Requests run in the background, so CALLBACK may run
long after the call returns."
  (if (etaf-ncm--client-p client)
      (etaf-ncm--client-request client request callback)
    (if (functionp client)
        (funcall client request callback)
      (signal 'etaf-ncm-error (list (format "Not a backend client: %S" client))))))

(defun etaf-ncm-cancel (client)
  "Abandon every in-flight request of CLIENT.
Cancelled requests never run their callbacks.  Return the number of cancelled
requests, or 0 when CLIENT is not a subprocess client."
  (let ((count 0))
    (when (etaf-ncm--client-p client)
      (dolist (pending (etaf-ncm--client-pending client))
        (setf (etaf-ncm--pending-cancelled pending) t)
        (when-let* ((timer (etaf-ncm--pending-timer pending)))
          (cancel-timer timer))
        (when-let* ((process (etaf-ncm--pending-process pending)))
          (when (process-live-p process)
            (cl-incf count)
            (delete-process process))))
      (setf (etaf-ncm--client-pending client) nil))
    count))

(defun etaf-ncm--player-live-p (client)
  "Return non-nil when CLIENT's backend player answers on its socket.
A stale socket left by a crashed mpv must read as not live: the stop below
would otherwise start a fresh daemon only to stop it, delaying Emacs exit."
  (when (etaf-ncm--client-p client)
    (let ((socket (expand-file-name
                   "mpv.sock" (etaf-ncm--client-state-directory client))))
      (and (file-exists-p socket)
           (condition-case nil
               (let ((process (make-network-process :name "etaf-ncm-mpv-probe"
                                                    :family 'local :service socket
                                                    :noquery t)))
                 (delete-process process)
                 t)
             (error nil))))))

(defun etaf-ncm--stop-synchronously (client)
  "Stop CLIENT's backend player without running the event loop.
`kill-emacs' runs no timers and waits for no asynchronous process, so the
stop request is executed through `call-process' instead of the client's
subprocess protocol.  A function client has no process to run, so it
gets the documented (:op :stop) request it can answer.  A player that is
not running is left alone, and every failure is ignored: quitting must
never fail because the backend is unavailable."
  (condition-case nil
      (if (etaf-ncm--client-p client)
          (when (etaf-ncm--player-live-p client)
            (let ((command (etaf-ncm--client-command client (list :op :stop)))
                  (process-environment (etaf-ncm--environment client)))
              (apply #'call-process (car command) nil nil nil (cdr command))))
        (etaf-ncm-client-call client (list :op :stop) #'ignore))
    (error nil)))

(defconst etaf-ncm--browse-resources
  '((:daily . "daily") (:liked . "liked") (:fm . "fm") (:recent . "recent")
    (:playlists . "myplaylists") (:charts . "charts") (:albums . "myalbums")
    (:artists . "myartists") (:podcasts . "podcasts"))
  "Library resources served by `netease-api.mjs'.")

(defconst etaf-ncm--cache-byte-limit (* 4 1024 1024)
  "Maximum size of the disposable local library snapshot.")

(defun etaf-ncm--client-cache-file (client)
  "Return CLIENT's local snapshot path; function clients default to memory."
  (when (etaf-ncm--client-p client)
    (expand-file-name "library-cache.eld" (etaf-ncm--client-state-directory client))))

(defun etaf-ncm--client-cache-identity (client)
  "Bind snapshots to CLIENT's credentials without storing credentials."
  (when (etaf-ncm--client-p client)
    (let ((file (expand-file-name "config.json" (etaf-ncm--client-state-directory client))))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents-literally file)
          (secure-hash 'sha256 (current-buffer)))))))

(defun etaf-ncm--cache-read (file identity)
  "Read bounded snapshot FILE for IDENTITY as data, never executable Lisp.
Missing, incompatible, corrupt and other-account snapshots are cache misses."
  (when (and file (not (file-remote-p file)) (file-readable-p file))
    (condition-case nil
        (when (<= (file-attribute-size (file-attributes file)) etaf-ncm--cache-byte-limit)
          (with-temp-buffer
            (insert-file-contents file)
            (let* ((read-circle nil)
                   (data (read (current-buffer))))
              (when (and (proper-list-p data) (equal (plist-get data :schema) 1)
                         (equal (plist-get data :identity) identity)
                         (proper-list-p (plist-get data :entries))
                         (<= (length (plist-get data :entries)) 16))
                (cl-remove-if-not
                 (lambda (entry)
                   (and (proper-list-p entry)
                        (let ((key (plist-get entry :key)))
                          (and (proper-list-p key) (= (length key) 2)
                               (eq (car key) :browse)
                               (assq (cadr key) etaf-ncm--browse-resources)))
                        (proper-list-p (plist-get entry :rows))
                        (numberp (plist-get entry :total)) (>= (plist-get entry :total) 0)
                        (numberp (plist-get entry :at)) (>= (plist-get entry :at) 0)))
                 (plist-get data :entries))))))
      (error nil))))

(defun etaf-ncm--cache-write (file identity entries)
  "Atomically save ENTRIES to FILE for IDENTITY with private permissions.
A second app's newer entries win over this app's older snapshot."
  (when (file-remote-p file)
    (signal 'etaf-ncm-error '("Library snapshots require a local file")))
  (let ((table (make-hash-table :test 'equal)) temporary)
    (dolist (entry (append (etaf-ncm--cache-read file identity) entries))
      (let* ((key (plist-get entry :key)) (old (gethash key table)))
        (when (and (numberp (plist-get entry :at))
                   (or (not (numberp (plist-get old :at)))
                       (>= (plist-get entry :at) (plist-get old :at))))
          (puthash key entry table))))
    (with-temp-buffer
      (let ((print-length nil) (print-level nil) (print-circle nil))
        (prin1 (list :schema 1 :identity identity
                     :entries (hash-table-values table)) (current-buffer)))
      (when (> (string-bytes (buffer-string)) etaf-ncm--cache-byte-limit)
        (signal 'etaf-ncm-error '("Library snapshot exceeds the size limit")))
      (make-directory (file-name-directory file) t)
      (unwind-protect
          (progn
            (setq temporary (make-temp-file (concat file ".")))
            (set-file-modes temporary #o600)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (point-min) (point-max) temporary nil 'silent))
            (rename-file temporary file t)
            (setq temporary nil))
        (when (and temporary (file-exists-p temporary)) (delete-file temporary))))))

(defconst etaf-ncm--translation-joiner "[_\uFF3F\u0332\u2017]+"
  "Characters NetEase joins a multi-line translation with.
Drawn as-is they read as stray underlines in the middle of a sentence.")

(defconst etaf-ncm--blank-runs "[\u3000\u00a0]+"
  "Blanks Ebox paints as a rule.
A full-width or no-break space has no glyph of its own, so the renderer fills it
with a line on the baseline: a lyric like `ある　so sweet' comes out underlined
at the gap.  A plain space is drawn as nothing, which is what the line means.")

(defun etaf-ncm--fold-joiners (text)
  "Return TEXT with translation joiners and painterly blanks folded to spaces.
Both ends fold: a lyric read from the cache and one parsed fresh must render the
same, and a page that already holds parsed lines still gets clean text."
  (if (stringp text)
      (replace-regexp-in-string etaf-ncm--blank-runs " "
                                (replace-regexp-in-string
                                 etaf-ncm--translation-joiner " " text))
    text))

(defun etaf-ncm-parse-lyric (text &optional translation)
  "Parse LRC TEXT into a list of (SECONDS . LINE) ordered by SECONDS.
Lines without a timestamp are dropped, empty ones are kept so pauses in the
song stay visible.  TRANSLATION folds the underscores NetEase joins a
multi-line translation with into spaces; a lyric line keeps its underscores,
which are part of a name there (a producer, an address)."
  (let ((joiner (and translation etaf-ncm--translation-joiner))
        entries)
    (dolist (line (split-string (or text "") "\n"))
      (when (string-match
             "\\`\\(?:\\[[0-9]+:[0-9]+\\(?:[.:][0-9]+\\)?\\]\\)+\\(.*\\)\\'" line)
        (let ((body (string-trim (match-string 1 line)))
              (start 0))
          (while (string-match "\\[\\([0-9]+\\):\\([0-9]+\\)\\(?:[.:]\\([0-9]+\\)\\)?\\]" line start)
            (setq start (match-end 0))
            (let* ((minutes (string-to-number (match-string 1 line)))
                   (seconds (string-to-number (match-string 2 line)))
                   (fraction (match-string 3 line))
                   (millis (if fraction
                               (/ (string-to-number fraction)
                                  (expt 10.0 (length fraction)))
                             0)))
              (push (cons (+ (* minutes 60) seconds millis)
                          (if joiner (replace-regexp-in-string joiner " " body) body))
                    entries))))))
    (sort (nreverse entries) (lambda (a b) (< (car a) (car b))))))

;;; ---------------------------------------------------------------------------
;;; Request translation
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm--play-commands
  '((:daily . "daily") (:liked . "liked") (:fm . "fm") (:playlist . "playlist")
    (:album . "album") (:artist . "artist") (:chart . "chart")
    (:podcast . "podcast") (:episode . "episode") (:song . "play")
    (:query . "play"))
  "Playback contexts accepted by `netease-music.sh'.
Keys are the keyword kinds used by play targets, exactly as in
`etaf-ncm--browse-resources'.")

(defun etaf-ncm--client-request (client request callback)
  "Run REQUEST through the backend processes of CLIENT, then call CALLBACK."
  (let* ((command (condition-case error
                      (etaf-ncm--client-command client request)
                    (error (funcall callback
                                    (list :error (error-message-string error)))
                           nil)))
         (transform (pcase (plist-get request :op)
                      (:queue (lambda (data)
                                (plist-put data :songs
                                           (etaf-ncm--queue-tracks client))))
                      (_ #'identity))))
    (when command
      (etaf-ncm--spawn client (car command) (cdr command)
                       (lambda (result)
                         (funcall callback
                                  (if (eq (car result) :ok)
                                      (list :ok (funcall transform (cadr result)))
                                    result)))
                       (plist-get request :timeout)))))

(defun etaf-ncm--client-command (client request)
  "Return the command line for REQUEST as (PROGRAM . ARGUMENTS).
The result is ready for `make-process': its first element is the program and
the rest are the arguments.  Signal `etaf-ncm-error' for an unknown request."
  (let* ((backend (etaf-ncm--client-backend-directory client))
         (api (expand-file-name "scripts/netease-api.mjs" backend))
         (cli (expand-file-name "scripts/netease-cli.mjs" backend))
         (music (expand-file-name "scripts/netease-music.sh" backend))
         (node (etaf-ncm--client-node-program client))
         (op (plist-get request :op)))
    (pcase op
      ((or :browse :search :lyric :session :liked-ids)
       (cons (etaf-ncm--program node api)
             (cons api (etaf-ncm--api-arguments request))))
      ;; Signing in and everything a playing session does go through the Node
      ;; entry: one implementation for every system, and it needs no shell.
      ((or :login-sms :login-sms-code :status :queue :play :add :jump
           :volume :seek :pause :resume :toggle :next :previous :stop
           :like :unlike :shuffle :repeat :cover)
       (cons (etaf-ncm--program node cli)
             (cons cli (etaf-ncm--cli-arguments request))))
      ;; Queue snapshots and downloads still live in the POSIX shell entry.
      ((or :queue-save :queue-load :download :downloads)
       (cons (etaf-ncm--script music)
             (append (list music) (etaf-ncm--script-arguments request)
                     (list "--json" "--quiet"))))
      (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request)))))))

(defun etaf-ncm--program (program script)
  "Return PROGRAM to run SCRIPT, verifying both exist."
  (unless (file-readable-p script)
    (signal 'etaf-ncm-error
            (list (format "Netease backend script is missing: %s" script))))
  (or (executable-find program)
      (signal 'etaf-ncm-error (list (format "Executable is missing: %s" program)))))

(defun etaf-ncm--script (script)
  "Return the shell program used to run SCRIPT.
Only POSIX systems run the shell entry.  Windows has no native `bash', and
the `bash.exe' it does have launches WSL, which cannot read the Windows path
SCRIPT is called with, so a request would exit 127 before reaching the
backend.  Windows is served by `netease-cli.mjs', which needs no shell."
  (unless (file-readable-p script)
    (signal 'etaf-ncm-error
            (list (format "Netease backend script is missing: %s" script))))
  (if (eq system-type 'windows-nt)
      (signal 'etaf-ncm-error
              '("Windows has no shell backend: this request needs a native implementation"))
    (or (executable-find "bash") "/bin/bash")))

(defun etaf-ncm--login-phone-argument (request)
  "Return REQUEST's digits-only phone number, or signal `etaf-ncm-error'."
  (let ((phone (string-trim (or (plist-get request :phone) ""))))
    (unless (string-match-p "\\`[0-9]\\{5,20\\}\\'" phone)
      (signal 'etaf-ncm-error
              (list (format "Login needs a 5-20 digit phone number: %S"
                            (plist-get request :phone)))))
    phone))

(defun etaf-ncm--login-code-argument (request)
  "Return REQUEST's digits-only SMS code, or signal `etaf-ncm-error'."
  (let ((code (string-trim (or (plist-get request :code) ""))))
    (unless (string-match-p "\\`[0-9]\\{3,8\\}\\'" code)
      (signal 'etaf-ncm-error
              (list (format "Login code must be 3-8 digits: %S" (plist-get request :code)))))
    code))

(defun etaf-ncm--limit (request fallback)
  "Return the `:limit' of REQUEST, or FALLBACK."
  (or (plist-get request :limit) fallback))

(defun etaf-ncm--api-arguments (request)
  "Return the netease-api.mjs arguments for REQUEST."
  (pcase (plist-get request :op)
    (:browse
     (let* ((resource (plist-get request :resource))
            (command (cdr (assq resource etaf-ncm--browse-resources))))
       (unless command
         (signal 'etaf-ncm-error (list (format "Unknown library: %S" resource))))
       (append (list command)
               (when (memq resource '(:daily :liked :fm :recent :playlists :albums
                                              :artists :podcasts))
                 (list "--limit" (number-to-string (etaf-ncm--limit request 50)))))))
    (:search
     (let ((keyword (or (plist-get request :keyword) "")))
       (when (string-empty-p (string-trim keyword))
         (signal 'etaf-ncm-error '("Search needs a keyword")))
       (if (eq (plist-get request :scope) 'playlist)
           (list "playlists" keyword "--limit"
                 (number-to-string (etaf-ncm--limit request 20)))
         (list "search" keyword "--limit"
               (number-to-string (etaf-ncm--limit request 30))))))
    (:lyric
     (let ((id (plist-get request :id)))
       (unless id (signal 'etaf-ncm-error '("Lyric needs a song id")))
       (list "lyric" (etaf-ncm--id id) "--trans")))
    (:session (list "session"))
    (:liked-ids (list "liked-ids"))
    (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request))))))

(defun etaf-ncm--login-arguments (request)
  "Return the netease-cli.mjs arguments for signing REQUEST in."
  (append (list "login" "--sms" (etaf-ncm--login-phone-argument request))
          (pcase (plist-get request :op)
            (:login-sms-code (list "--sms-code" (etaf-ncm--login-code-argument request)))
            (_ nil))
          (list "--json")))

(defun etaf-ncm--play-arguments (request)
  "Return the netease-cli.mjs arguments that start playing REQUEST.
IDS plays that order from scratch; otherwise the target's kind selects the
list to build the queue from, the way the shell entry used to."
  (let* ((target (plist-get request :target))
         (ids (plist-get request :ids))
         (kind (plist-get target :kind))
         (command (if ids "play-ids" (cdr (assq kind etaf-ncm--play-commands)))))
    (unless command
      (signal 'etaf-ncm-error (list (format "Cannot play: %S" target))))
    (let ((argument (plist-get target :id))
          (start (plist-get request :start)))
      (when (and start (not (and ids (integerp start) (> start 0)
                                 (<= start (length ids)))))
        (signal 'etaf-ncm-error (list (format "Invalid start: %S" start))))
      (when (and ids (not (and (proper-list-p ids)
                               (cl-every (lambda (id) (and (integerp id) (> id 0))) ids))))
        (signal 'etaf-ncm-error '("Play ids must be positive integers")))
      (when (memq kind '(:song :query :playlist :album :artist :chart :podcast :episode))
        (unless (and argument (not (string-empty-p (format "%s" argument))))
          (signal 'etaf-ncm-error (list (format "Cannot play: %S" target)))))
      (append (list command)
              (if ids
                  (list (mapconcat #'number-to-string ids ","))
                (when (memq kind '(:song :query :playlist :album :artist :chart :podcast :episode))
                  (list (etaf-ncm--id argument))))
              (when start (list "--start" (number-to-string start)))
              (when (and (not ids) (plist-get request :shuffle)) (list "--shuffle"))
              (when (and (not ids) (plist-get request :limit))
                (list "--limit" (number-to-string (plist-get request :limit))))))))

(defun etaf-ncm--cli-arguments (request)
  "Return the netease-cli.mjs arguments for REQUEST.
The Node entry answers the same requests on every system, so these arguments
do not depend on a shell being present."
  (append
   (pcase (plist-get request :op)
     (:status '("status"))
     (:queue (list "queue" "--limit"
                   (number-to-string (etaf-ncm--limit request 200))))
     (:login-sms (etaf-ncm--login-arguments request))
     (:login-sms-code (etaf-ncm--login-arguments request))
     (:play (etaf-ncm--play-arguments request))
     (:add
      (let ((id (plist-get request :id)))
        (unless id (signal 'etaf-ncm-error '("Add needs a song id")))
        (list "add" (etaf-ncm--id id))))
     (:jump
      (let ((index (plist-get request :index)))
        (unless (and (integerp index) (> index 0))
          (signal 'etaf-ncm-error (list (format "Invalid queue index: %S" index))))
        (list "jump" (number-to-string index))))
     (:volume
      (if-let* ((value (plist-get request :value)))
          (progn
            (unless (and (numberp value) (<= 0 value 130))
              (signal 'etaf-ncm-error (list (format "Invalid volume: %S" value))))
            (list "volume" (number-to-string (round value))))
        (list "volume")))
     (:seek
      (let ((seconds (plist-get request :seconds)))
        (unless (numberp seconds)
          (signal 'etaf-ncm-error (list (format "Invalid seek: %S" seconds))))
        (list "seek" (if (>= seconds 0)
                         (number-to-string (round seconds))
                       (format "-%d" (abs (round seconds)))))))
     (:shuffle (list "shuffle" (if (plist-get request :on) "on" "off")))
     (:repeat (list "repeat" (if (plist-get request :on) "on" "off")))
     (:pause '("pause"))
     (:resume '("resume"))
     (:toggle '("toggle"))
     (:next '("next"))
     (:previous '("prev"))
     (:stop '("stop"))
     (:like '("like"))
     (:unlike '("unlike"))
     (:cover
      (let ((id (plist-get request :id))
            (file (plist-get request :file)))
        (unless (and (integerp id) (> id 0))
          (signal 'etaf-ncm-error (list (format "Cover needs a song id: %S" id))))
        (unless (and (stringp file) (not (string-empty-p file)))
          (signal 'etaf-ncm-error (list (format "Cover needs a destination file: %S" file))))
        (list "cover" (etaf-ncm--id id) "--download" file "--force")))
     (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request)))))
   (list "--json")))

(defun etaf-ncm--script-arguments (request)
  "Return the netease-music.sh arguments for REQUEST.
Only the requests that still live in the POSIX shell entry are left here."
  (pcase (plist-get request :op)
    (:queue-save
     (append (list "queue-save") (when-let* ((name (plist-get request :name)))
                                   (list (format "%s" name)))))
    (:queue-load
     (let ((name (plist-get request :name)))
       (unless (and name (not (string-empty-p (format "%s" name))))
         (signal 'etaf-ncm-error '("queue-load needs a saved name")))
       (list "queue-load" (format "%s" name))))
    (:download
     (let ((id (plist-get request :id)))
       (unless (and (numberp id) (> id 0))
         (signal 'etaf-ncm-error (list (format "Invalid song id: %S" id))))
       (append (list "download" (etaf-ncm--id id))
               (when-let* ((level (plist-get request :level)))
                 (list "--level" (format "%s" level)))
               (when (plist-get request :force) (list "--force")))))
    (:downloads (list "downloads"))
    (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request))))))

(defun etaf-ncm--id (value)
  "Return VALUE as a command argument string."
  (if (numberp value) (number-to-string value) (format "%s" value)))

;;; ---------------------------------------------------------------------------
;;; Child processes
;;; ---------------------------------------------------------------------------

(cl-defun etaf-ncm--spawn (client program arguments callback &optional request-timeout)
  "Run PROGRAM with ARGUMENTS for CLIENT; deliver its decoded JSON to CALLBACK.
REQUEST-TIMEOUT, when given, replaces CLIENT's own request timeout."
  (let* ((stdout (generate-new-buffer " *etaf-ncm-stdout*"))
         (stderr (generate-new-buffer " *etaf-ncm-stderr*"))
         (pending (etaf-ncm--pending-create :stdout stdout :stderr stderr))
         (timeout (or request-timeout (etaf-ncm--client-timeout client))))
    (condition-case error
        (progn
          (setf (etaf-ncm--pending-process pending)
                ;; `make-process' has no :environment keyword, so the child's
                ;; environment comes from a binding around the call.
                (let ((process-environment (etaf-ncm--environment client)))
                  (make-process
                   :name "etaf-ncm"
                   :buffer stdout
                   :stderr stderr
                   :command (cons program arguments)
                   :connection-type 'pipe
                   :noquery t
                   :coding 'utf-8-unix)))
          ;; The stderr pipe is a process of its own; without a sentinel Emacs
          ;; appends a "Process ... finished" line to its buffer on exit,
          ;; which is not backend output.  An ignoring sentinel keeps the
          ;; buffer to exactly what the backend wrote.
          (let ((pipe (get-buffer-process stderr)))
            (when pipe (set-process-sentinel pipe #'ignore))))
      (error
       (kill-buffer stdout)
       (kill-buffer stderr)
       (funcall callback (list :error (error-message-string error)))
       (cl-return-from etaf-ncm--spawn nil)))
    (push pending (etaf-ncm--client-pending client))
    (setf (etaf-ncm--pending-timer pending)
          (run-at-time
           timeout nil
           (lambda ()
             (setf (etaf-ncm--pending-cancelled pending) t)
             (when-let* ((process (etaf-ncm--pending-process pending)))
               (when (process-live-p process) (delete-process process)))
             (setf (etaf-ncm--client-pending client)
                   (delq pending (etaf-ncm--client-pending client)))
             (funcall callback
                      (list :error (format "Backend request timed out after %ss" timeout)
                            :hint (mapconcat #'identity (cons program arguments) " "))))))
    (set-process-sentinel
     (etaf-ncm--pending-process pending)
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal failed))
         (etaf-ncm--settle client pending process callback))))
    nil))

(defun etaf-ncm--settle (client pending process callback)
  "Collect the result of PROCESS and finish PENDING for CLIENT.
The callback is skipped when the request was cancelled."
  (let ((stdout (etaf-ncm--pending-stdout pending))
        (stderr (etaf-ncm--pending-stderr pending))
        (cancelled (etaf-ncm--pending-cancelled pending)))
    (when-let* ((timer (etaf-ncm--pending-timer pending)))
      (cancel-timer timer))
    (setf (etaf-ncm--client-pending client)
          (delq pending (etaf-ncm--client-pending client)))
    ;; An exited process can still have output in flight: `:stderr' is its own
    ;; pipe, so the exit event may arrive before its data.  A zero timeout
    ;; reads what is already in the pipe without waiting — the exit means the
    ;; writer finished, so its bytes are in the kernel buffer — and it avoids
    ;; the "Blocking call to accept-process-output with quit inhibited"
    ;; warning a timeout-less wait would print from this sentinel.
    (unless cancelled
      (while (accept-process-output process 0))
      (let ((pipe (get-buffer-process stderr)))
        (while (and pipe (accept-process-output pipe 0)))))
    (let ((output (with-current-buffer stdout (buffer-string)))
          (errors (with-current-buffer stderr (buffer-string)))
          (status (process-exit-status process)))
      (kill-buffer stdout)
      (kill-buffer stderr)
      ;; Re-read the cancellation flag: draining the streams can run a timer
      ;; that times this request out, which already delivered the failure.
      (unless (or cancelled (etaf-ncm--pending-cancelled pending))
        (funcall callback
                 (if (and (eq (process-status process) 'exit) (zerop status))
                     (let ((data (etaf-ncm--decode output)))
                       (cond ((null data) (list :error "Backend returned no data"
                                                :hint (string-trim errors)))
                             ((eq (plist-get data :ok) :false)
                              (etaf-ncm--failure data errors))
                             (t (list :ok data))))
                   (let ((data (etaf-ncm--decode output)))
                     (if data
                         (etaf-ncm--failure data errors)
                       (or (etaf-ncm--stderr-failure errors)
                           (list :error (format "Backend command failed (exit %s)" status)
                                 :hint (string-trim errors)))))))))))

(defun etaf-ncm--failure (data errors)
  "Return an (:error ...) result built from backend DATA and ERRORS."
  (let* ((code (plist-get data :error))
         (message (or (plist-get data :message)
                      (plist-get data :conclusion)
                      code
                      "Backend request failed"))
         (hint (or (plist-get data :hint) (string-trim errors))))
    (append (list :error (if (stringp message) message (format "%s" message)))
            (when (and code (stringp code) (not (string-equal code message)))
              (list :code code))
            (when (and hint (not (string-empty-p hint))) (list :hint hint)))))

(defun etaf-ncm--decode (output)
  "Decode the first JSON object in OUTPUT, or nil."
  (when (and output (not (string-empty-p (string-trim output))))
    (condition-case nil
        (json-parse-string (string-trim output)
                           :object-type 'plist
                           :array-type 'list
                           :null-object nil
                           :false-object :false)
      (error nil))))

(defun etaf-ncm--stderr-failure (errors)
  "Return the backend's own failure report in stderr ERRORS as a result plist.
A netease-music script that refuses a command reports why on stderr and exits
non-zero: the shell entry writes one `error=CODE' and one `hint=TEXT' line,
and the mpv bridge writes the same two fields as a JSON object.  That report
names the failure for a person, so it becomes what the caller sees instead of
the bare exit status.  Return (:error TEXT [:code CODE]), or nil when ERRORS
carries no such report."
  (let* ((data (etaf-ncm--decode errors))
         (code (etaf-ncm--nonempty-text
                (or (plist-get data :error) (etaf-ncm--stderr-field errors "error"))))
         (hint (etaf-ncm--nonempty-text
                (or (plist-get data :hint) (etaf-ncm--stderr-field errors "hint")))))
    (when code
      (let ((message (or hint code)))
        (append (list :error message)
                (unless (string-equal code message) (list :code code)))))))

(defun etaf-ncm--nonempty-text (value)
  "Return VALUE when it is a non-empty string, or nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun etaf-ncm--stderr-field (errors name)
  "Return the value of the first `NAME=' line in stderr ERRORS, or nil.
The value is the rest of that line."
  (let ((prefix (concat name "=")))
    (cl-loop for line in (split-string (or errors "") "\n")
             when (string-prefix-p prefix line)
             return (substring line (length prefix)))))

(defun etaf-ncm--environment (client)
  "Return the process environment for CLIENT's child processes.
The stored login cookie is exported in the names the backend reads, and the
state directory is passed explicitly, so the backend and the queue panel always
agree on one place.  A UTF-8 locale is
forced when the parent has none: the backend prints and parses Chinese text,
and under a C locale its shell reads a multibyte character after a variable
name as part of that name."
  (let* ((cookie (etaf-ncm--cookie client))
         (existing (or (getenv "LC_ALL") (getenv "LC_CTYPE") (getenv "LANG")))
         (utf8 (and existing (string-match-p "\\(?:UTF-8\\|utf8\\)" existing)))
         (base (seq-remove (lambda (entry)
                             (or (string-prefix-p "NETEASE_COOKIE=" entry)
                                 (and (not utf8)
                                      (or (string-prefix-p "LC_ALL=" entry)
                                          (string-prefix-p "LC_CTYPE=" entry)
                                          (string-prefix-p "LANG=" entry)))))
                           process-environment)))
    (append
     base
     (list (concat "NETEASE_MUSIC_STATE_DIR="
                   (etaf-ncm--client-state-directory client)))
     (unless utf8
       (list (concat "LC_CTYPE=" (if (eq system-type 'darwin) "en_US.UTF-8" "C.UTF-8"))))
     (when (and cookie (not (string-empty-p cookie)))
       (list (concat "NETEASE_COOKIE=" cookie))))))

(defun etaf-ncm--state-value (client key)
  "Return the string stored under KEY in CLIENT's state config, or nil.
The backend keeps its login state in that file; a missing file, a missing key
or a non-string value reads as nil."
  (let ((file (expand-file-name
               "config.json" (etaf-ncm--client-state-directory client))))
    (when (file-readable-p file)
      (let ((data (etaf-ncm--decode
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (let ((value (plist-get data key)))
          (and (stringp value) (not (string-empty-p value)) value))))))

(defun etaf-ncm--cookie (client)
  "Return the NetEase login cookie known to CLIENT, or nil.
The process environment wins over the state file, matching the backend's own
resolution order; a missing cookie is not an error here, because the backend
reports the login failure with its own message."
  (or (getenv "NETEASE_COOKIE")
      (etaf-ncm--state-value client :cookie)))

(defun etaf-ncm--stored-phone (client)
  "Return the phone number CLIENT's backend remembers, or nil.
The backend stores it after the first SMS sign-in, so the player can offer it
as the default when signing in again.  A function client has no state file."
  (when (etaf-ncm--client-p client)
    (etaf-ncm--state-value client :phone)))

(defun etaf-ncm--queue-tracks (client)
  "Return the queue track list recorded by the backend for CLIENT.
The list comes from the backend's documented `queue.json' state file; the
current index always comes from the backend command, so a stale file cannot
invent a playing position."
  (let ((file (expand-file-name "queue.json" (etaf-ncm--client-state-directory client))))
    (when (file-readable-p file)
      (let ((data (etaf-ncm--decode
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (delq nil (mapcar #'etaf-ncm--normalize-track (plist-get data :songs)))))))

(defun etaf-ncm--normalize-track (track)
  "Return TRACK with numeric id, duration and a real VIP flag."
  (when (listp track)
    (list :id (etaf-ncm--number (plist-get track :id))
          :name (etaf-ncm--string (plist-get track :name))
          :artist (etaf-ncm--string (plist-get track :artist))
          :album (etaf-ncm--string (plist-get track :album))
          :ms (etaf-ncm--number (plist-get track :ms))
          :vip (eq t (plist-get track :vip))
          :cover (etaf-ncm--string (plist-get track :cover)))))

(defun etaf-ncm--list (value)
  "Return VALUE as a proper list of elements.
JSON arrays decode to vectors, so every sequence a view or a model walks goes
through here: accept lists, vectors, and nothing else."
  (cond ((null value) nil)
        ((listp value) value)
        ((vectorp value) (append value nil))
        (t nil)))

(defun etaf-ncm--number (value)
  "Return VALUE as a number, or nil."
  (cond ((numberp value) value)
        ((and (stringp value) (string-match-p "\\`[0-9]+\\'" (string-trim value)))
         (string-to-number (string-trim value)))
        ((eq value t) nil)
        ((and value (not (string-empty-p (string-trim (format "%s" value)))))
         (string-to-number (format "%s" value)))
        (t nil)))

(defun etaf-ncm--string (value)
  "Return VALUE as a string; `:false' and nil become the empty string."
  (cond ((null value) "")
        ((eq value :false) "")
        ((stringp value) value)
        ((numberp value) (number-to-string value))
        (t (format "%s" value))))

(provide 'etaf-ncm-service)
;;; etaf-ncm-service.el ends here
