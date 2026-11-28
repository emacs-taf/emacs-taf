;;; etaf-island-model.el --- Pure-protocol shell session for ETAF Island -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Headless shell state for `etaf-island'.  Owns ONLY shell presentation state
;; (compact/expanded/alert mode, active tab, keyboard selection index, custom
;; dragged anchor, appearance, active pulse and sensor preferences); all live
;; activity and notification data comes strictly from ETAF's `etaf-activity-ref'
;; and `etaf-notify-ref'.

;;; Code:

(require 'cl-lib)
(require 'etaf)
(require 'etaf-island-theme)
(require 'etaf-island-sensors)

(defconst etaf-island--valid-modes '(compact expanded alert)
  "Supported display modes of an ETAF Island session.")

(defconst etaf-island--valid-tabs '(activities events quick)
  "Supported expanded-panel tabs of an ETAF Island session.")

(defconst etaf-island--app-labels
  '((etaf-ncm . "网易云音乐")
    (etaf-pomodoro . "番茄钟")
    (etaf-translate . "沉浸式翻译")
    (etaf-telega . "Telegram")
    (etaf-agenda . "今日日程")
    (etaf-rss . "RSS 订阅")
    (etaf-bili . "哔哩哔哩")
    (etaf-ext . "扩展引擎")
    (compile . "编译构建")
    (org-clock . "Org 计时"))
  "Friendly localized names for common ETAF ecosystem publishers.")

(defun etaf-island--app-label (app)
  "Return a friendly display name for publisher symbol APP, or nil."
  (when app
    (or (cdr (assq app etaf-island--app-labels))
        (if (symbolp app) (symbol-name app) (format "%s" app)))))

(defun etaf-island--require-session (session)
  "Validate SESSION plist and return it, or signal `etaf-island-error'."
  (unless (and (listp session) (eq (plist-get session :kind) 'etaf-island-session))
    (signal 'etaf-island-error (list "Expected an ETAF Island session" session)))
  session)

(defun etaf-island--format-clock (seconds)
  "Format nonnegative SECONDS as MM:SS."
  (let* ((secs (max 0 (floor seconds)))
         (mins (/ secs 60))
         (rem (% secs 60)))
    (format "%02d:%02d" mins rem)))

;;;###autoload
(cl-defun etaf-island-create (&key (appearance 'auto) (mode 'compact) (tab 'activities))
  "Create and return a new headless ETAF Island shell session.
APPEARANCE is `auto', `dark' or `light'; MODE is `compact', `expanded' or
`alert'; TAB is `activities', `events' or `quick'."
  (unless (memq mode etaf-island--valid-modes)
    (signal 'etaf-island-error (list "Invalid island mode" mode)))
  (unless (memq tab etaf-island--valid-tabs)
    (signal 'etaf-island-error (list "Invalid island tab" tab)))
  (unless (memq appearance '(auto dark light))
    (signal 'etaf-island-error (list "Invalid appearance" appearance)))
  (list :kind 'etaf-island-session
        :mode (etaf-ref mode :name 'island-mode)
        :tab (etaf-ref tab :name 'island-tab)
        :selection (etaf-ref 0 :name 'island-selection)
        :custom-anchor (etaf-ref nil :name 'island-custom-anchor :test #'equal)
        :appearance (etaf-ref appearance :name 'island-appearance)
        :active-alert (etaf-ref (when (eq mode 'alert) (car (etaf-notify-list)))
                                :name 'island-active-alert :test #'equal)
        :alert-generation (etaf-ref 0 :name 'island-alert-gen)
        :auto-hide-idle (etaf-ref (and etaf-island-auto-hide-idle t) :name 'island-auto-hide)
        :sense-compile (etaf-ref (and etaf-island-sense-compilation t) :name 'island-sense-compile)
        :sense-org-clock (etaf-ref (and etaf-island-sense-org-clock t) :name 'island-sense-clock)))

;;;###autoload
(defun etaf-island-state (session)
  "Return a plain read-only snapshot plist of SESSION and live protocol state."
  (etaf-island--require-session session)
  (list :mode (etaf-untracked (etaf-value (plist-get session :mode)))
        :tab (etaf-untracked (etaf-value (plist-get session :tab)))
        :selection (etaf-untracked (etaf-value (plist-get session :selection)))
        :custom-anchor (etaf-untracked (etaf-value (plist-get session :custom-anchor)))
        :appearance (etaf-untracked (etaf-value (plist-get session :appearance)))
        :activities (etaf-activity-list)
        :notifications (etaf-notify-list)
        :active-alert (etaf-untracked
                       (etaf-value (plist-get session :active-alert)))
        :auto-hide-idle (etaf-untracked
                         (etaf-value (plist-get session :auto-hide-idle)))))

;;;###autoload
(defun etaf-island-set-mode (session mode)
  "Switch SESSION's display mode to MODE (`compact', `expanded' or `alert')."
  (etaf-island--require-session session)
  (unless (memq mode etaf-island--valid-modes)
    (signal 'etaf-island-error (list "Invalid island mode" mode)))
  (etaf-batch
    (setf (etaf-value (plist-get session :mode)) mode)
    (when (eq mode 'expanded)
      (setf (etaf-value (plist-get session :selection)) 0))
    (when (and (eq mode 'alert)
               (null (etaf-untracked
                      (etaf-value (plist-get session :active-alert)))))
      (setf (etaf-value (plist-get session :active-alert))
            (car (etaf-notify-list)))))
  mode)

;;;###autoload
(defun etaf-island-select-tab (session tab)
  "Select expanded TAB (`activities', `events' or `quick') in SESSION."
  (etaf-island--require-session session)
  (unless (memq tab etaf-island--valid-tabs)
    (signal 'etaf-island-error (list "Invalid island tab" tab)))
  (etaf-batch
    (setf (etaf-value (plist-get session :tab)) tab)
    (setf (etaf-value (plist-get session :selection)) 0)
    (unless (eq (etaf-untracked (etaf-value (plist-get session :mode))) 'expanded)
      (setf (etaf-value (plist-get session :mode)) 'expanded)))
  tab)

(defun etaf-island--cycle-tab (session delta)
  "Move SESSION's active tab forward or backward by DELTA steps."
  (etaf-island--require-session session)
  (let* ((cur (etaf-untracked (etaf-value (plist-get session :tab))))
         (idx (or (cl-position cur etaf-island--valid-tabs) 0))
         (next (nth (mod (+ idx delta) (length etaf-island--valid-tabs))
                    etaf-island--valid-tabs)))
    (etaf-island-select-tab session next)))

(defun etaf-island--clamp-index (index count)
  "Clamp integer INDEX cleanly into [0, COUNT - 1], or 0 when COUNT <= 0."
  (if (<= (or count 0) 0)
      0
    (max 0 (min (1- count) (or index 0)))))

(defun etaf-island--move-selection (session delta count)
  "Move SESSION's keyboard selection index by DELTA within COUNT items."
  (etaf-island--require-session session)
  (when (> count 0)
    (let* ((ref (plist-get session :selection))
           (cur (etaf-island--clamp-index (etaf-untracked (etaf-value ref)) count))
           (next (mod (+ cur delta) count)))
      (setf (etaf-value ref) next)
      next)))

;;;###autoload
(defun etaf-island-reset-position (session)
  "Clear SESSION's dragged position override so the floating island re-centers."
  (etaf-island--require-session session)
  (setf (etaf-value (plist-get session :custom-anchor)) nil)
  t)

;;;###autoload
(defun etaf-island-toggle-appearance (session)
  "Cycle SESSION appearance through `auto', `dark' and `light' and return it."
  (etaf-island--require-session session)
  (let* ((ref (plist-get session :appearance))
         (cur (etaf-untracked (etaf-value ref)))
         (next (pcase cur ('auto 'dark) ('dark 'light) (_ 'auto))))
    (setf (etaf-value ref) next)
    next))

(defun etaf-island--pulse-alert (session entry)
  "Pulse SESSION into alert mode with notification ENTRY unless expanded."
  (when (and session entry)
    (etaf-batch
      (setf (etaf-value (plist-get session :active-alert)) entry
            (etaf-value (plist-get session :alert-generation))
            (1+ (etaf-untracked (etaf-value (plist-get session :alert-generation)))))
      (unless (eq (etaf-untracked (etaf-value (plist-get session :mode))) 'expanded)
        (setf (etaf-value (plist-get session :mode)) 'alert)))))

;;;###autoload
(defun etaf-island-dismiss-notification (session &optional id)
  "Dismiss notification ID (or the active alert) via `etaf-notify-dismiss'."
  (etaf-island--require-session session)
  (let* ((alert-ref (plist-get session :active-alert))
         (active (etaf-untracked (etaf-value alert-ref)))
         (target-id (or id (and active (plist-get active :id))))
         (remaining (etaf-notify-dismiss target-id)))
    (when (or (null id) (and active (equal target-id (plist-get active :id))))
      (etaf-batch
        (setf (etaf-value alert-ref) nil)
        (when (eq (etaf-untracked (etaf-value (plist-get session :mode))) 'alert)
          (setf (etaf-value (plist-get session :mode)) 'compact))))
    remaining))

;;;###autoload
(defun etaf-island-clear-notifications (session)
  "Clear all notifications via `etaf-notify-clear' and collapse alerts."
  (etaf-island--require-session session)
  (etaf-notify-clear)
  (etaf-batch
    (setf (etaf-value (plist-get session :active-alert)) nil)
    (when (eq (etaf-untracked (etaf-value (plist-get session :mode))) 'alert)
      (setf (etaf-value (plist-get session :mode)) 'compact)))
  nil)

(defun etaf-island--activity-has-action-p (entry action-id)
  "Return non-nil when activity ENTRY declares ACTION-ID (or `:open')."
  (if (eq action-id 'open)
      (or (functionp (plist-get entry :open))
          (cl-some (lambda (a) (eq (plist-get a :id) 'open))
                   (plist-get entry :actions)))
    (cl-some (lambda (a) (eq (plist-get a :id) action-id))
             (plist-get entry :actions))))

(defun etaf-island--invoke-primary-kind (kind action-id)
  "Safely invoke ACTION-ID on the highest-priority activity supporting it."
  (let* ((items (if kind (etaf-activity-list kind) (etaf-activity-list)))
         (target (cl-find-if (lambda (a)
                               (etaf-island--activity-has-action-p a action-id))
                             items)))
    (when target
      (condition-case err
          (etaf-activity-invoke (plist-get target :id) action-id)
        (error (message "ETAF Island: %s" (error-message-string err)) nil)))))

(defun etaf-island--safe-call (fn)
  "Run zero-argument callback FN safely, isolating errors."
  (when (functionp fn)
    (condition-case err
        (funcall fn)
      (error (message "ETAF Island: %s" (error-message-string err)) nil))))

(provide 'etaf-island-model)
;;; etaf-island-model.el ends here
