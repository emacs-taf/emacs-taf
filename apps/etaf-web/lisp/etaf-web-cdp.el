;;; etaf-web-cdp.el --- Persistent CDP bridge client for Tier 3 live pages -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Manages a single shared `backends/cdp-bridge/bridge.mjs' subprocess over
;; line-delimited JSON (NDJSON) stdio pipes via `make-process'.  All network
;; and browser operations stay strictly asynchronous and never block Emacs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'etaf-web-cache)

(defcustom etaf-web-node-program "node"
  "Node.js executable (version 22+) used to run the Tier 3 CDP bridge."
  :type 'string
  :group 'etaf-web)

(defcustom etaf-web-live-enabled t
  "Whether Tier 3 live CDP interactive rendering is enabled when available."
  :type 'boolean
  :group 'etaf-web)

(defvar etaf-web-cdp--proc nil
  "Live NDJSON bridge process, or nil when stopped.")

(defvar etaf-web-cdp--stderr-buf nil
  "Buffer collecting bridge stderr diagnostics.")

(defvar etaf-web-cdp--line-buf ""
  "Partial stdout line buffer awaiting newline completion.")

(defvar etaf-web-cdp--next-id 1
  "Monotonic RPC request identifier.")

(defvar etaf-web-cdp--tab-seq 0
  "Monotonic logical tab identifier counter.")

(defvar etaf-web-cdp--pending (make-hash-table :test #'eql)
  "Map from RPC id to callback `(RESULT ERR-MSG)'.")

(defvar etaf-web-cdp--tab-handlers (make-hash-table :test #'equal)
  "Map from logical tab id string to push-event handler `(MSG)'.")

(defvar etaf-web-cdp--node-ok-cache 'unknown
  "Cached result of Node.js 22+ availability probe (`t', `nil' or `unknown').")

;;; ---------------------------------------------------------------------------
;;; Resource discovery & availability check
;;; ---------------------------------------------------------------------------

(defun etaf-web-cdp--bridge-script ()
  "Locate `backends/cdp-bridge/bridge.mjs' across checkout and package roots."
  (let* ((this-dir (and load-file-name (file-name-directory load-file-name)))
         (lib-file (or (locate-library "etaf-web")
                       (locate-library "etaf-web-cdp")))
         (lib-dir (and lib-file (file-name-directory lib-file)))
         (candidates
          (delq nil
                (list (and this-dir
                           (expand-file-name "../backends/cdp-bridge/bridge.mjs" this-dir))
                      (and this-dir
                           (expand-file-name "backends/cdp-bridge/bridge.mjs" this-dir))
                      (and lib-dir
                           (expand-file-name "backends/cdp-bridge/bridge.mjs" lib-dir))
                      (and lib-dir
                           (expand-file-name "../backends/cdp-bridge/bridge.mjs" lib-dir))))))
    (cl-find-if #'file-readable-p candidates)))

(defun etaf-web-cdp--node-supported-p ()
  "Return non-nil when `etaf-web-node-program' is installed and >= Node 22."
  (if (not (eq etaf-web-cdp--node-ok-cache 'unknown))
      etaf-web-cdp--node-ok-cache
    (let* ((exe (and (stringp etaf-web-node-program)
                     (executable-find etaf-web-node-program)))
           (ok (when exe
                 (condition-case nil
                     (with-temp-buffer
                       (when (eql 0 (call-process exe nil t nil "-v"))
                         (let ((ver (string-trim (buffer-string))))
                           (and (string-match "\\`v\\([0-9]+\\)" ver)
                                (>= (string-to-number (match-string 1 ver)) 22)))))
                   (error nil)))))
      (setq etaf-web-cdp--node-ok-cache (and ok t)))))

(defun etaf-web-cdp-available-p ()
  "Return non-nil when Tier 3 live CDP rendering can run on this machine."
  (and etaf-web-live-enabled
       (etaf-web-cdp--node-supported-p)
       (etaf-web--browser-program)
       (etaf-web-cdp--bridge-script)
       t))

(defun etaf-web-cdp--profile-dir ()
  "Return persistent Chromium profile directory for Tier 3 CDP sessions."
  (let ((dir (expand-file-name "cdp-profile"
                               (expand-file-name etaf-web-cache-directory))))
    (make-directory dir t)
    dir))

;;; ---------------------------------------------------------------------------
;;; Process lifecycle & NDJSON framing
;;; ---------------------------------------------------------------------------

(defun etaf-web-cdp--fail-all-pending (reason)
  "Reject every pending RPC callback with REASON."
  (let ((callbacks nil))
    (maphash (lambda (_k cb) (push cb callbacks)) etaf-web-cdp--pending)
    (clrhash etaf-web-cdp--pending)
    (dolist (cb callbacks)
      (ignore-errors (funcall cb nil reason)))))

(defun etaf-web-cdp--dispatch-line (line)
  "Parse one NDJSON LINE from the bridge and dispatch to pending/event handlers."
  (let ((trimmed (string-trim line)))
    (unless (string-empty-p trimmed)
      (condition-case nil
          (let* ((msg (json-parse-string trimmed
                                         :object-type 'plist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil))
                 (id (plist-get msg :id))
                 (event (plist-get msg :event)))
            (cond
             ((integerp id)
              (when-let* ((cb (gethash id etaf-web-cdp--pending)))
                (remhash id etaf-web-cdp--pending)
                (if (plist-get msg :ok)
                    (funcall cb (plist-get msg :result) nil)
                  (funcall cb nil (or (plist-get msg :error) "CDP bridge error")))))
             ((equal event "snapshot")
              (when-let* ((tab (plist-get msg :tab))
                          (handler (gethash tab etaf-web-cdp--tab-handlers)))
                (funcall handler msg)))
             ((equal event "bridge_closed")
              (etaf-web-cdp--fail-all-pending
               (or (plist-get msg :reason) "Chromium bridge closed")))))
        (error nil)))))

(defun etaf-web-cdp--filter (_proc chunk)
  "Process filter assembling NDJSON lines from CHUNK."
  (setq etaf-web-cdp--line-buf (concat etaf-web-cdp--line-buf chunk))
  (let ((start 0)
        (pos nil))
    (while (setq pos (string-match "\n" etaf-web-cdp--line-buf start))
      (let ((line (substring etaf-web-cdp--line-buf start pos)))
        (setq start (1+ pos))
        (etaf-web-cdp--dispatch-line line)))
    (when (> start 0)
      (setq etaf-web-cdp--line-buf (substring etaf-web-cdp--line-buf start)))))

(defun etaf-web-cdp--sentinel (proc event)
  "Process sentinel handling unexpected bridge exits."
  (when (eq proc etaf-web-cdp--proc)
    (when (memq (process-status proc) '(exit signal failed))
      (setq etaf-web-cdp--proc nil
            etaf-web-cdp--line-buf "")
      (etaf-web-cdp--fail-all-pending
       (format "CDP bridge exited: %s" (string-trim event))))))

(defun etaf-web-cdp--ensure-proc ()
  "Ensure the shared CDP bridge subprocess is running and return it."
  (if (and etaf-web-cdp--proc (process-live-p etaf-web-cdp--proc))
      etaf-web-cdp--proc
    (let ((node (executable-find etaf-web-node-program))
          (script (etaf-web-cdp--bridge-script))
          (chrome (etaf-web--browser-program)))
      (unless (and node (etaf-web-cdp--node-supported-p))
        (signal 'etaf-web-error '("Tier 3 live mode requires Node.js 22 or newer")))
      (unless script
        (signal 'etaf-web-error '("Cannot locate etaf-web CDP bridge script")))
      (unless chrome
        (signal 'etaf-web-error '("No Chromium/Chrome executable found for live mode")))
      (setq etaf-web-cdp--line-buf "")
      (unless (buffer-live-p etaf-web-cdp--stderr-buf)
        (setq etaf-web-cdp--stderr-buf
              (generate-new-buffer " *etaf-web-cdp-stderr*")))
      (let* ((process-environment
              (append (list (concat "ETAF_WEB_CHROME=" chrome)
                            (concat "ETAF_WEB_CDP_PROFILE=" (etaf-web-cdp--profile-dir))
                            (if (null url-proxy-services)
                                "ETAF_WEB_NO_PROXY=1"
                              "ETAF_WEB_NO_PROXY=0"))
                      process-environment))
             (proc (make-process
                    :name "etaf-web-cdp-bridge"
                    :command (list node script)
                    :connection-type 'pipe
                    :coding 'utf-8-unix
                    :noquery t
                    :stderr etaf-web-cdp--stderr-buf
                    :filter #'etaf-web-cdp--filter
                    :sentinel #'etaf-web-cdp--sentinel)))
        (when-let* ((pipe (get-buffer-process etaf-web-cdp--stderr-buf)))
          (set-process-sentinel pipe #'ignore))
        (setq etaf-web-cdp--proc proc)
        proc))))

(defun etaf-web-cdp--send-rpc (op params callback)
  "Send NDJSON RPC request OP with PARAMS alist; call CALLBACK `(RES ERR)'."
  (condition-case err
      (let* ((proc (etaf-web-cdp--ensure-proc))
             (id etaf-web-cdp--next-id)
             (payload (append (list (cons 'id id) (cons 'op op)) params))
             (wire (concat (json-encode payload) "\n")))
        (setq etaf-web-cdp--next-id (1+ id))
        (when (functionp callback)
          (puthash id callback etaf-web-cdp--pending))
        (process-send-string proc wire)
        id)
    (error
     (when (functionp callback)
       (funcall callback nil (error-message-string err)))
     nil)))

;;; ---------------------------------------------------------------------------
;;; High-level tab operations & shutdown
;;; ---------------------------------------------------------------------------

(defun etaf-web-cdp--new-tab-id ()
  "Allocate a unique logical tab id string."
  (setq etaf-web-cdp--tab-seq (1+ etaf-web-cdp--tab-seq))
  (format "tab-%d" etaf-web-cdp--tab-seq))

(defun etaf-web-cdp--open-tab (tab-id url on-event callback &optional width height include-html)
  "Open URL in logical TAB-ID, registering ON-EVENT and invoking CALLBACK.
When INCLUDE-HTML is non-nil, requests the post-hydration DOM HTML alongside IR."
  (when (functionp on-event)
    (puthash tab-id on-event etaf-web-cdp--tab-handlers))
  (etaf-web-cdp--send-rpc
   "open"
   (delq nil
         (list (cons 'tab tab-id)
               (cons 'url url)
               (cons 'chrome (etaf-web--browser-program))
               (cons 'profile (etaf-web-cdp--profile-dir))
               (when width (cons 'width width))
               (when height (cons 'height height))
               (when include-html (cons 'includeHtml t))))
   callback))

(cl-defun etaf-web-cdp--act (tab-id kind &key wid value submit delta-y callback)
  "Execute DOM action KIND on TAB-ID via the live CDP bridge."
  (etaf-web-cdp--send-rpc
   "act"
   (delq nil
         (list (cons 'tab tab-id)
               (cons 'kind kind)
               (when wid (cons 'wid wid))
               (when (not (null value)) (cons 'value value))
               (when submit (cons 'submit t))
               (when delta-y (cons 'deltaY delta-y))))
   callback))

(defun etaf-web-cdp--snapshot (tab-id callback)
  "Request a fresh distilled Web IR snapshot for TAB-ID."
  (etaf-web-cdp--send-rpc "snapshot" (list (cons 'tab tab-id)) callback))

(defun etaf-web-cdp--close-tab (tab-id)
  "Close logical TAB-ID and unregister its event subscriber."
  (remhash tab-id etaf-web-cdp--tab-handlers)
  (when (and etaf-web-cdp--proc (process-live-p etaf-web-cdp--proc))
    (etaf-web-cdp--send-rpc "close" (list (cons 'tab tab-id)) nil)))

(defun etaf-web-cdp-shutdown ()
  "Shut down the shared Tier 3 CDP bridge and its Chromium process cleanly."
  (interactive)
  (clrhash etaf-web-cdp--tab-handlers)
  (etaf-web-cdp--fail-all-pending "CDP bridge shut down")
  (when (and etaf-web-cdp--proc (process-live-p etaf-web-cdp--proc))
    (let ((proc etaf-web-cdp--proc)
          (deadline (+ (float-time) 1.5)))
      (setq etaf-web-cdp--proc nil
            etaf-web-cdp--line-buf "")
      (ignore-errors
        (process-send-string proc "{\"id\":0,\"op\":\"shutdown\"}\n"))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.05))
      (when (process-live-p proc)
        (ignore-errors (delete-process proc)))))
  (when (buffer-live-p etaf-web-cdp--stderr-buf)
    (ignore-errors (kill-buffer etaf-web-cdp--stderr-buf))
    (setq etaf-web-cdp--stderr-buf nil)))

(add-hook 'kill-emacs-hook #'etaf-web-cdp-shutdown)

(provide 'etaf-web-cdp)
;;; etaf-web-cdp.el ends here
