;;; etaf-weread-service.el --- WeChat Reading backend client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The reader does not re-implement the WeChat Reading protocol.  It drives the
;; backend bundled under the package's `backends/' through its command line:
;;
;;   node <backend>/weread.mjs COMMAND ... --json --quiet
;;
;; Every command prints JSON.  Requests are plists such as
;; (:op :shelf :filter reading :limit 200) and every call is asynchronous:
;; CALLBACK runs later in the Emacs event loop with (:ok DATA) or
;; (:error MESSAGE :hint HINT).  Nothing here blocks, so the interface keeps
;; repainting while a request is in flight.
;;
;; Tests replace the transport by binding `etaf-weread-client-factory' to a
;; function returning a fake client, so no scenario needs the network or a
;; login.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'etaf)
(require 'etaf-weread-theme)

(defcustom etaf-weread-backend-directory
  (expand-file-name "backends/weread"
                    (file-name-directory (or (locate-library "etaf-weread")
                                             load-file-name
                                             buffer-file-name)))
  "Directory holding this package's WeChat Reading backend.
The backend ships with the package and is installed from the same archive, so it
needs no separate download or environment setup."
  :type 'directory
  :group 'etaf-weread)

(defcustom etaf-weread-node-program "node"
  "Node executable used to run the bundled backend."
  :type 'string
  :group 'etaf-weread)

(defcustom etaf-weread-request-timeout 45
  "Seconds before a backend request is abandoned.
The timer kills the child process, so a hung request cannot pin a pending
callback forever.  Callers see (:error MESSAGE)."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-login-timeout 300
  "Seconds `etaf-weread-login' waits for the browser login.
The backend waits up to three minutes for a QR scan, so signing in needs a
wider deadline than `etaf-weread-request-timeout'."
  :type 'number
  :group 'etaf-weread)

(defcustom etaf-weread-export-directory nil
  "Directory the backend writes exported Markdown into, or nil for its default.
When non-nil it is passed to the backend as `--out', which wins over the
backend's own configuration."
  :type '(choice (const :tag "Backend default" nil) directory)
  :group 'etaf-weread)

(defvar etaf-weread-client-factory nil
  "Function returning the backend client used by new sessions.
It is called with no arguments and must return a client built by
`etaf-weread-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-weread-client-call' documents.  Nil selects the default subprocess
client; tests bind this to a fake client.")

(cl-defstruct (etaf-weread--client (:constructor etaf-weread--client-create))
  "Backend client that runs the bundled backend as child processes.
PENDING lists the `etaf-process-run' jobs still in flight."
  backend-directory node-program timeout (pending nil))

(cl-defun etaf-weread-make-client (&key backend-directory node-program timeout)
  "Create a client that runs the bundled backend as child processes.
BACKEND-DIRECTORY, NODE-PROGRAM and TIMEOUT default to
`etaf-weread-backend-directory', `etaf-weread-node-program' and
`etaf-weread-request-timeout'."
  (etaf-weread--client-create
   :backend-directory (or backend-directory etaf-weread-backend-directory)
   :node-program (or node-program etaf-weread-node-program)
   :timeout (or timeout etaf-weread-request-timeout)))

(defun etaf-weread-client-call (client request callback)
  "Send REQUEST through CLIENT and deliver the reply to CALLBACK.
CLIENT is a client from `etaf-weread-make-client' or a function of two
arguments (REQUEST CALLBACK), which is how tests inject a fake.

REQUEST is a plist whose `:op' selects one backend operation:

  :status    (:op :status)                              the stored login
  :login     (:op :login)                               sign in / refresh it
  :logout    (:op :logout)                              delete the stored login
  :shelf     (:op :shelf :filter all :limit 200)        books and progress
  :notebook  (:op :notebook :limit 200)                 books with notes
  :book      (:op :book :id \"3300144445\")              info, TOC and progress
  :notes     (:op :notes :id \"3300144445\")             highlights and thoughts
  :search    (:op :search :keyword \"三体\" :count 25)
  :stats     (:op :stats)                               aggregate reading stats
  :export    (:op :export :id \"3300144445\")            write the notes Markdown

A request may carry `:timeout SECONDS' to widen the subprocess deadline for
one call; signing in needs it because the browser waits for a QR scan.

CALLBACK receives exactly one of (:ok DATA), where DATA is the decoded JSON
plist, or (:error MESSAGE :hint HINT) when the command failed, timed out or
returned a backend error.  Requests run in the background, so CALLBACK may run
long after the call returns."
  (if (etaf-weread--client-p client)
      (etaf-weread--client-request client request callback)
    (if (functionp client)
        (funcall client request callback)
      (signal 'etaf-weread-error (list (format "Not a backend client: %S" client))))))

(defun etaf-weread-cancel (client)
  "Abandon every in-flight request of CLIENT.
Cancelled requests never run their callbacks.  Return the number of cancelled
requests, or 0 when CLIENT is not a subprocess client."
  (let ((count 0))
    (when (etaf-weread--client-p client)
      (dolist (job (etaf-weread--client-pending client))
        (when (etaf-process-cancel job)
          (cl-incf count)))
      (setf (etaf-weread--client-pending client) nil))
    count))

(defun etaf-weread--client-request (client request callback)
  "Run REQUEST through the backend process of CLIENT, then call CALLBACK."
  (let ((command (condition-case error
                     (etaf-weread--client-command client request)
                   (error (funcall callback
                                   (list :error (error-message-string error)))
                          nil))))
    (when command
      (etaf-weread--spawn client (car command) (cdr command) callback
                           :timeout (plist-get request :timeout)))))

(defun etaf-weread--client-command (client request)
  "Return the command line for REQUEST as (PROGRAM . ARGUMENTS).
The result is ready for `make-process': its first element is the program and
the rest are the arguments.  Signal `etaf-weread-error' for an unknown request."
  (let* ((backend (etaf-weread--client-backend-directory client))
         (script (expand-file-name "weread.mjs" backend))
         (node (etaf-weread--client-node-program client)))
    (unless (file-readable-p script)
      (signal 'etaf-weread-error
              (list (format "weread backend script is missing: %s" script))))
    (unless (executable-find node)
      (signal 'etaf-weread-error (list (format "Executable is missing: %s" node))))
    (cons node
          (append (list script)
                  (etaf-weread--command-arguments request)
                  (list "--json" "--quiet")
                  (etaf-weread--export-arguments request)))))

(defun etaf-weread--command-arguments (request)
  "Return the backend command arguments for REQUEST.
Only `:export' writes, and it always overrides the backend's preview default
with `--yes' because the reader asks before calling this function."
  (let ((op (plist-get request :op))
        (id (plist-get request :id))
        (limit (or (plist-get request :limit) 200)))
    (pcase op
      (:status (list "status"))
      (:login (list "login"))
      (:logout (list "logout"))
      (:shelf (append (list "shelf" "--filter"
                            (or (plist-get request :filter) "all"))
                      (list "--limit" (number-to-string limit))))
      (:notebook (list "notes" "--limit" (number-to-string limit)))
      ((or :book :notes)
       (unless (and id (not (string-empty-p (format "%s" id))))
         (signal 'etaf-weread-error (list (format "%s needs a book id" op))))
       (list (if (eq op :book) "book" "notes") (format "%s" id)))
      (:search
       (let ((keyword (string-trim (or (plist-get request :keyword) ""))))
         (when (string-empty-p keyword)
           (signal 'etaf-weread-error '("搜索关键词不能为空")))
         (list "search" keyword "--count"
               (number-to-string (or (plist-get request :count) 25)))))
      (:stats (list "stats"))
      (:export
       (unless (and id (not (string-empty-p (format "%s" id))))
         (signal 'etaf-weread-error '("export needs a book id")))
       (list "export" (format "%s" id) "--yes"))
      (_ (signal 'etaf-weread-error (list (format "Unknown request: %S" request)))))))

(defun etaf-weread--export-arguments (request)
  "Return extra arguments of REQUEST, currently only the export directory."
  (when (and (eq (plist-get request :op) :export)
             etaf-weread-export-directory)
    (list "--out" (expand-file-name etaf-weread-export-directory))))

(cl-defun etaf-weread--spawn (client program arguments callback &key timeout)
  "Run PROGRAM with ARGUMENTS for CLIENT; deliver its decoded JSON to CALLBACK.
TIMEOUT overrides the client's deadline for this call, in seconds."
  (let* ((timeout (or timeout (etaf-weread--client-timeout client)))
         (command (cons program arguments))
         (job nil))
    (setq job (etaf-process-run
               command :name "etaf-weread" :output 'json :timeout timeout
               :callback
               (lambda (result)
                 (setf (etaf-weread--client-pending client)
                       (delq job (etaf-weread--client-pending client)))
                 (funcall callback
                          (etaf-weread--result result command timeout)))))
    (push job (etaf-weread--client-pending client))
    nil))

(defun etaf-weread--result (result command timeout)
  "Return the client reply for the `etaf-process-run' RESULT of COMMAND.
TIMEOUT is the deadline the command ran with, named in a timeout failure."
  (let ((data (plist-get result :output))
        (errors (or (plist-get result :stderr) "")))
    (pcase (plist-get result :status)
      ('timeout (list :error (format "Backend request timed out after %ss" timeout)
                      :hint (mapconcat #'identity command " ")))
      ('failed (list :error (plist-get result :message)))
      ((and 'exit (guard (eql (plist-get result :exit) 0)))
       (cond ((null data) (list :error "Backend returned no data"
                                :hint (string-trim errors)))
             ((eq (plist-get data :ok) :false) (etaf-weread--failure data errors))
             (t (list :ok data))))
      (_ (if data
             (etaf-weread--failure data errors)
           (list :error (format "Backend command failed (exit %s)"
                                (plist-get result :exit))
                 :hint (string-trim errors)))))))

(defun etaf-weread--failure (data errors)
  "Return an (:error ...) result built from backend DATA and ERRORS.
The backend's `message' is the human sentence; `error' is its stable code and is
kept beside the message so callers can throttle a failed refresh."
  (let ((message (or (plist-get data :message)
                     (plist-get data :error)
                     (plist-get data :conclusion)
                     "Backend request failed"))
        (code (plist-get data :error))
        (hint (or (plist-get data :hint) (string-trim errors))))
    (append (list :error (if (stringp message) message (format "%s" message)))
            (when (and code (stringp code) (not (string-equal code message)))
              (list :code code))
            (when (and hint (not (string-empty-p hint))) (list :hint hint)))))

(provide 'etaf-weread-service)
;;; etaf-weread-service.el ends here
