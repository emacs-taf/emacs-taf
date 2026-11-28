;;; etaf-desktop-apps.el --- ETAF application registry and sessions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'cl-lib)
(require 'etaf)
(require 'etaf-desktop-runtime)

(declare-function etaf-desktop-layout-floating-windows "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-layout-mode "etaf-desktop-layout"
                  (desktop &optional workspace))
(declare-function etaf-desktop-set-layout-mode "etaf-desktop-layout"
                  (desktop mode &optional workspace))
(declare-function etaf-desktop-layout-set-tree "etaf-desktop-layout"
                  (desktop tree &optional workspace))
(declare-function etaf-desktop-layout-tree "etaf-desktop-layout"
                  (desktop &optional workspace))

;; This module owns application policy only.  Geometry and rendering continue
;; to go through the public `etaf-desktop-open-window' and related APIs.

(cl-defstruct (etaf-desktop--app
               (:constructor etaf-desktop--app-create))
  id title icon open close serialize restore capabilities default-window)

(cl-defstruct (etaf-desktop--instance
               (:constructor etaf-desktop--instance-create))
  id app-id status options state windows error restore-data)

(cl-defstruct (etaf-desktop--app-store
               (:constructor etaf-desktop--app-store-create))
  instances next-id)

(defvar etaf-desktop--apps (make-hash-table :test #'equal)
  "Registered ETAF application manifests keyed by application ID.")

;; A weak key keeps a controller's application instances from keeping the
;; controller alive after its buffer and caller references are released.
(defvar etaf-desktop--app-stores
  (make-hash-table :test #'eq :weakness 'key)
  "Per-desktop application instance stores.")

(defun etaf-desktop--validate-app-id (id)
  "Validate and return stable application ID ID."
  (unless (or (and (symbolp id) (not (null id)))
              (and (stringp id) (not (string-empty-p id))))
    (etaf-desktop--fail "Application ID must be a symbol or nonempty string: %S" id))
  id)

(defun etaf-desktop--app-store (desktop)
  "Return the instance store for DESKTOP, creating it when needed."
  (let ((desktop (etaf-desktop--controller desktop)))
    (or (gethash desktop etaf-desktop--app-stores)
        (puthash desktop
                 (etaf-desktop--app-store-create
                  :instances (make-hash-table :test #'equal) :next-id 1)
                 etaf-desktop--app-stores))))

(defun etaf-desktop--instance-has-visible-window-p (desktop instance)
  "Return non-nil when INSTANCE owns a visible, non-minimized window."
  (cl-some
   (lambda (window-id)
     (let ((state (condition-case nil
                      (etaf-desktop-window-state desktop window-id)
                    (etaf-desktop-error nil))))
       (and state
            (plist-get state :visible)
            (not (plist-get state :minimized)))))
   (etaf-desktop--instance-windows instance)))

(defun etaf-desktop--instance-visible-status (desktop instance)
  "Return INSTANCE's status from its visible windows and DESKTOP focus."
  (if (not (etaf-desktop--instance-has-visible-window-p desktop instance))
      'suspended
    (if (member (etaf-desktop-active-window desktop)
                (etaf-desktop--instance-windows instance))
        'active
      'inactive)))

(defun etaf-desktop--application-window-event (desktop window-id event)
  "Keep application instances synchronized with WINDOW-ID EVENT.

The geometry runtime calls this private integration point after a direct
window operation.  It lets title-bar actions and application-owned calls share
the same lifecycle semantics without making the runtime depend on the app
registry.  Closing an instance's last window invokes its manifest close
callback once; closing one of several windows only removes that window from
the instance record."
  (when-let* ((store (gethash desktop etaf-desktop--app-stores)))
    (when (eq event 'focus-cleared)
      (etaf-desktop--deactivate-other-instances store nil))
    (maphash
     (lambda (_instance-id instance)
       (when (member window-id (etaf-desktop--instance-windows instance))
         (pcase event
           ('closed
            (setf (etaf-desktop--instance-windows instance)
                  (delete window-id
                          (etaf-desktop--instance-windows instance)))
            (unless (memq (etaf-desktop--instance-status instance)
                          '(closing closed error))
              (if (etaf-desktop--instance-windows instance)
                  (setf (etaf-desktop--instance-status instance)
                        (etaf-desktop--instance-visible-status desktop instance))
                ;; A user closing the last app window is the app-level close
                ;; operation.  Keep callback failures isolated in the same
                ;; way as `etaf-desktop-close-instance'.
                (setf (etaf-desktop--instance-status instance) 'closing)
                (let ((app (gethash (etaf-desktop--instance-app-id instance)
                                    etaf-desktop--apps))
                      (callback-error nil))
                  (when (and app (etaf-desktop--app-close app))
                    (condition-case err
                        (funcall (etaf-desktop--app-close app)
                                 (etaf-desktop--instance-context desktop instance)
                                 'window-close)
                      (error (setq callback-error
                                    (error-message-string err)))))
                  (setf (etaf-desktop--instance-status instance)
                        (if callback-error 'error 'closed)
                        (etaf-desktop--instance-error instance)
                        callback-error)))))
           ((or 'focused 'restored)
            (unless (memq (etaf-desktop--instance-status instance)
                          '(closed error))
              (etaf-desktop--deactivate-other-instances store
                                                         (etaf-desktop--instance-id instance))
              (setf (etaf-desktop--instance-status instance) 'active)))
           ('minimized
            (unless (memq (etaf-desktop--instance-status instance)
                          '(closed error closing))
              (setf (etaf-desktop--instance-status instance)
                    (etaf-desktop--instance-visible-status desktop instance)))))))
     (etaf-desktop--app-store-instances store))))

(defun etaf-desktop--app (id)
  "Return registered app ID ID or signal a public desktop error."
  (or (gethash id etaf-desktop--apps)
      (etaf-desktop--fail "Unknown ETAF application: %S" id)))

(defun etaf-desktop--app-plist (app)
  "Return a detached manifest plist for APP."
  (list :id (etaf-desktop--app-id app)
        :title (etaf-desktop--app-title app)
        :icon (etaf-desktop--app-icon app)
        :capabilities (copy-sequence (etaf-desktop--app-capabilities app))
        :default-window (copy-tree (etaf-desktop--app-default-window app))))

(defun etaf-desktop--instance-plist (instance)
  "Return a detached public state plist for INSTANCE."
  (list :id (etaf-desktop--instance-id instance)
        :app-id (etaf-desktop--instance-app-id instance)
        :status (etaf-desktop--instance-status instance)
        :options (copy-tree (etaf-desktop--instance-options instance))
        :state (copy-tree (etaf-desktop--instance-state instance))
        :windows (copy-sequence (etaf-desktop--instance-windows instance))
        :error (etaf-desktop--instance-error instance)))

(defun etaf-desktop--instance-context (desktop instance)
  "Build callback context for INSTANCE in DESKTOP."
  (list :desktop desktop
        :app-id (etaf-desktop--instance-app-id instance)
        :instance-id (etaf-desktop--instance-id instance)
        :options (copy-tree (etaf-desktop--instance-options instance))
        :state (etaf-desktop--instance-state instance)
        :restore-data (etaf-desktop--instance-restore-data instance)
        :windows (copy-sequence (etaf-desktop--instance-windows instance))))

(defun etaf-desktop--instance (desktop id)
  "Return instance ID ID for DESKTOP or signal an error."
  (or (gethash id (etaf-desktop--app-store-instances
                   (etaf-desktop--app-store desktop)))
      (etaf-desktop--fail "Unknown ETAF application instance: %S" id)))

(defun etaf-desktop--window-specs (result default-window)
  "Normalize callback RESULT into a list of window spec plists.
DEFAULT-WINDOW supplies missing values from an app manifest."
  (let ((windows (plist-get result :windows)))
    (cond
     ((listp windows) windows)
     ((or (plist-member result :view) (plist-member result :title))
      (list result))
     ((and (listp default-window) default-window)
      (list default-window))
     (t nil))))

(defun etaf-desktop--window-option (spec key fallback)
  "Get KEY from SPEC, falling back to FALLBACK when absent."
  (if (plist-member spec key) (plist-get spec key) fallback))

(defun etaf-desktop--open-instance-windows (desktop instance result app &optional workspace)
  "Open windows described by RESULT for INSTANCE and return their IDs.
When WORKSPACE is non-nil it fills a missing spec workspace."
  (let ((specs (etaf-desktop--window-specs
                (or result '()) (etaf-desktop--app-default-window app)))
        (index 0)
        ids)
    (condition-case err
        (progn
          (dolist (spec specs)
            (setq index (1+ index))
            (when (and workspace (not (plist-member spec :workspace)))
              (setq spec (plist-put (copy-sequence spec) :workspace workspace)))
            (let* ((local-id (or (plist-get spec :id) index))
                   ;; The desktop token keeps this ID, and every ETAF Host
                   ;; reference derived from it, unique when desktops embed
                   ;; each other: two levels can otherwise both run
                   ;; "etaf-manual-1/main" and shadow each other's Hosts.
                   (id (format "%s/%s/%s" (etaf-desktop--controller-token desktop)
                               (etaf-desktop--instance-id instance) local-id))
                   (window (etaf-desktop-open-window
                            desktop id
                            :title (or (plist-get spec :title)
                                       (etaf-desktop--app-title app)
                                       (format "%s" (etaf-desktop--instance-app-id instance)))
                            :view (plist-get spec :view)
                            :x (or (plist-get spec :x) 0)
                            :y (or (plist-get spec :y) 0)
                            :width (or (plist-get spec :width) 400)
                            :height (or (plist-get spec :height) 12)
                            :min-width (or (plist-get spec :min-width) 160)
                            :min-height (or (plist-get spec :min-height) 3)
                            :max-width (plist-get spec :max-width)
                            :max-height (plist-get spec :max-height)
                            :workspace (plist-get spec :workspace)
                            :visible (if (plist-member spec :visible)
                                         (plist-get spec :visible) t)
                            :movable (if (plist-member spec :movable)
                                         (plist-get spec :movable) t)
                            :resizable (if (plist-member spec :resizable)
                                           (plist-get spec :resizable) t))))
              (push (plist-get window :id) ids)))
          (nreverse ids))
      (error
       ;; Window creation is a transaction at the application boundary.  A
       ;; later invalid spec must not leave already-created windows detached
       ;; from the failed instance's error placeholder.
       (dolist (id ids)
         (ignore-errors (etaf-desktop-close-window desktop id)))
       (signal (car err) (cdr err))))))

(defun etaf-desktop--placeholder (desktop instance message)
  "Open a visible error placeholder for INSTANCE with MESSAGE."
  (condition-case _err
      (let ((window (etaf-desktop-open-window
                     desktop (format "%s/%s/error" (etaf-desktop--controller-token desktop)
                                     (etaf-desktop--instance-id instance))
                     :title (format "ETAF app error: %s"
                                    (etaf-desktop--instance-app-id instance))
                     :view (etaf-desktop--frame-body message)
                     :min-width 260 :min-height 4)))
        (setf (etaf-desktop--instance-windows instance)
              (list (plist-get window :id))))
    (error nil)))

(defun etaf-desktop--record-instance-error (desktop instance err)
  "Record ERR on INSTANCE and isolate it from DESKTOP."
  (setf (etaf-desktop--instance-status instance) 'error
        (etaf-desktop--instance-error instance)
        (error-message-string err))
  (etaf-desktop--placeholder desktop instance (etaf-desktop--instance-error instance))
  (etaf-desktop--instance-plist instance))

(defun etaf-desktop--next-instance-id (store app-id)
  "Allocate an instance ID from STORE for APP-ID."
  (let ((id nil))
    (while (progn
             (setq id (format "%s-%d" app-id (etaf-desktop--app-store-next-id store)))
             (setf (etaf-desktop--app-store-next-id store)
                   (1+ (etaf-desktop--app-store-next-id store)))
             (gethash id (etaf-desktop--app-store-instances store))))
    id))

(defun etaf-desktop--deactivate-other-instances (store active-id)
  "Mark active instances other than ACTIVE-ID as inactive in STORE."
  (maphash
   (lambda (id instance)
     (when (and (not (equal id active-id))
                (eq (etaf-desktop--instance-status instance) 'active))
       (setf (etaf-desktop--instance-status instance) 'inactive)))
   (etaf-desktop--app-store-instances store)))

(defun etaf-desktop--restore-window-state (desktop id state)
  "Apply saved window STATE to window ID in DESKTOP when it exists."
  (when (and (listp state)
             (condition-case nil (etaf-desktop-window-state desktop id)
               (etaf-desktop-error nil)))
    (let* ((maximized (plist-get state :maximized))
           (minimized (plist-get state :minimized))
           (normal (plist-get state :normal-geometry))
           (x (or (and (listp normal) (nth 0 normal))
                  (plist-get state :x) 0))
           (y (or (and (listp normal) (nth 1 normal))
                  (plist-get state :y) 0))
           (width (or (and (listp normal) (nth 2 normal))
                      (plist-get state :width) 400))
           (height (or (and (listp normal) (nth 3 normal))
                       (plist-get state :height) 12)))
      ;; Restore is host policy, not a user's move/resize gesture.  Fixed
      ;; windows and tiles compressed below their requested minimums are
      ;; legitimate saved rectangles too.
      (etaf-desktop--number x "saved x" 0)
      (etaf-desktop--number y "saved y" 0)
      (etaf-desktop--number width "saved width" 1)
      (etaf-desktop--number height "saved height" 1)
      (etaf-desktop--update
       desktop
       (lambda (next)
         (let ((window (etaf-desktop--window-for next id)))
           (setf (etaf-desktop--window-x window) x
                 (etaf-desktop--window-y window) y
                 (etaf-desktop--window-width window) width
                 (etaf-desktop--window-height window) height
                 (etaf-desktop--window-normal-geometry window)
                 (list x y width height)))))
      (when maximized (etaf-desktop-maximize-window desktop id))
      (when minimized (etaf-desktop-minimize-window desktop id)))))

(cl-defun etaf-desktop-register-app
    (id &key title icon open close serialize restore capabilities default-window replace)
  "Register application ID with its manifest callbacks.

OPEN receives one context plist containing `:desktop', `:app-id',
`:instance-id', `:options', `:state' and `:restore-data'.  It returns either a
window spec plist or `:windows' followed by a list of window specs.  Each spec
may contain the arguments accepted by `etaf-desktop-open-window'.  CLOSE,
SERIALIZE and RESTORE receive the same context; CLOSE additionally receives a
reason symbol, SERIALIZE returns application-owned data, and RESTORE returns
an OPEN-compatible result.  `:replace' allows replacing an idle manifest."
  (setq id (etaf-desktop--validate-app-id id))
  (when (and (gethash id etaf-desktop--apps) (not replace))
    (etaf-desktop--fail "ETAF application already registered: %S" id))
  (when (and open (not (functionp open)))
    (etaf-desktop--fail "Application OPEN callback is not callable: %S" open))
  (dolist (callback (list close serialize restore))
    (when (and callback (not (functionp callback)))
      (etaf-desktop--fail "Application callback is not callable: %S" callback)))
  (puthash id (etaf-desktop--app-create
               :id id :title title :icon icon :open open :close close
               :serialize serialize :restore restore
               :capabilities (copy-sequence capabilities)
               :default-window (copy-tree default-window))
           etaf-desktop--apps)
  (etaf-desktop--app-plist (gethash id etaf-desktop--apps)))

(defun etaf-desktop-unregister-app (id &optional force)
  "Remove manifest ID and return non-nil.
When FORCE is nil, signal if any desktop still has a live instance of ID."
  (setq id (etaf-desktop--validate-app-id id))
  (unless force
    (maphash
     (lambda (_desktop store)
       (maphash
        (lambda (_instance-id instance)
          (when (and (equal id (etaf-desktop--instance-app-id instance))
                     (not (memq (etaf-desktop--instance-status instance)
                                '(closed error))))
            (etaf-desktop--fail "Application has a live instance: %S" id)))
        (etaf-desktop--app-store-instances store)))
     etaf-desktop--app-stores))
  (remhash id etaf-desktop--apps))

(defun etaf-desktop-app (id)
  "Return a detached manifest plist for registered application ID."
  (etaf-desktop--app-plist (etaf-desktop--app id)))

(defun etaf-desktop-apps ()
  "Return detached manifests for all registered applications."
  (let (result)
    (maphash (lambda (_id app) (push (etaf-desktop--app-plist app) result))
             etaf-desktop--apps)
    (sort result (lambda (a b) (string< (format "%s" (plist-get a :id))
                                        (format "%s" (plist-get b :id)))))))

(defun etaf-desktop-app-registered-p (id)
  "Return non-nil when application ID is registered."
  (and (gethash id etaf-desktop--apps) t))

(defun etaf-desktop--single-instance-app-p (app)
  "Return non-nil when APP declares no `multiple-instances' capability."
  (not (memq 'multiple-instances (etaf-desktop--app-capabilities app))))

(defun etaf-desktop--running-instance (store app-id)
  "Return APP-ID's newest instance in STORE that is neither closed nor failed."
  (let (found)
    (maphash
     (lambda (_id instance)
       (when (and (equal app-id (etaf-desktop--instance-app-id instance))
                  (not (memq (etaf-desktop--instance-status instance)
                             '(closed error))))
         (setq found instance)))
     (etaf-desktop--app-store-instances store))
    found))

(cl-defun etaf-desktop-launch
    (desktop app-id &key instance-id options restore-data restore workspace)
  "Launch APP-ID in DESKTOP and return its instance state plist.
An application failure is isolated to an `error' instance and an error
placeholder window; the desktop remains usable.  INSTANCE-ID is stable across
session restore.  RESTORE-DATA is passed to the app's restore callback;
RESTORE forces that callback even when its saved value is nil.  An implicit
launch of an application without the `multiple-instances' capability focuses
its running instance instead of starting a second one; session restore passes
INSTANCE-ID and keeps creating every recorded instance."
  (let* ((desktop (etaf-desktop--controller desktop))
         (app (etaf-desktop--app (etaf-desktop--validate-app-id app-id)))
         (store (etaf-desktop--app-store desktop))
         (running (and (null instance-id)
                       (etaf-desktop--single-instance-app-p app)
                       (etaf-desktop--running-instance store app-id))))
    (if running
        (or (etaf-desktop-focus-instance desktop
                                        (etaf-desktop--instance-id running))
            (etaf-desktop--instance-plist running))
      (etaf-desktop--launch-new-instance
       desktop app store app-id instance-id options restore-data restore
       workspace))))

(cl-defun etaf-desktop--launch-new-instance
    (desktop app store app-id instance-id options restore-data restore workspace)
  "Create one new APP-ID instance in DESKTOP and return its state plist."
  (let* ((id (or instance-id (etaf-desktop--next-instance-id store app-id)))
         (instances (etaf-desktop--app-store-instances store)))
    (when (gethash id instances)
      (etaf-desktop--fail "Application instance already exists: %S" id))
    (let ((instance (etaf-desktop--instance-create
                     :id id :app-id app-id :status 'launching
                     :options (copy-tree options) :state nil :windows nil
                     :error nil :restore-data restore-data)))
      (puthash id instance instances)
      (condition-case err
          (let* ((context (etaf-desktop--instance-context desktop instance))
                 (result (if (and (or restore restore-data)
                                  (etaf-desktop--app-restore app))
                             (funcall (etaf-desktop--app-restore app) context restore-data)
                           (if (etaf-desktop--app-open app)
                               (funcall (etaf-desktop--app-open app) context)
                             (list :title (etaf-desktop--app-title app)
                                   :workspace workspace))))
                 (ids (etaf-desktop--open-instance-windows desktop instance result app workspace)))
            (etaf-desktop--deactivate-other-instances store
                                                       (etaf-desktop--instance-id instance))
            (setf (etaf-desktop--instance-state instance)
                  (if (plist-member result :state)
                      (plist-get result :state)
                    (etaf-desktop--instance-state instance))
                  (etaf-desktop--instance-windows instance) ids
                  (etaf-desktop--instance-status instance) 'active
                  (etaf-desktop--instance-error instance) nil)
            (etaf-desktop--instance-plist instance))
        (error (etaf-desktop--record-instance-error desktop instance err))))))

(defun etaf-desktop-instances (desktop)
  "Return detached application instance states for DESKTOP."
  (let (result)
    (maphash (lambda (_id instance) (push (etaf-desktop--instance-plist instance) result))
             (etaf-desktop--app-store-instances (etaf-desktop--app-store desktop)))
    (sort result (lambda (a b) (string< (format "%s" (plist-get a :id))
                                        (format "%s" (plist-get b :id)))))))

(defun etaf-desktop-instance (desktop id)
  "Return detached state for application instance ID in DESKTOP."
  (etaf-desktop--instance-plist (etaf-desktop--instance desktop id)))

(defun etaf-desktop-set-instance-state (desktop id state)
  "Set caller-owned application STATE for instance ID and return its state."
  (let ((instance (etaf-desktop--instance desktop id)))
    (setf (etaf-desktop--instance-state instance) state)
    state))

(defun etaf-desktop-focus-instance (desktop id)
  "Focus the first visible window belonging to application instance ID."
  (let ((instance (etaf-desktop--instance desktop id)))
    (unless (memq (etaf-desktop--instance-status instance) '(closed error))
      (let ((window (cl-find-if
                     (lambda (window-id)
                       (let ((state (condition-case nil
                                         (etaf-desktop-window-state desktop window-id)
                                       (etaf-desktop-error nil))))
                         (and state (plist-get state :visible))))
                     (etaf-desktop--instance-windows instance))))
        (if window
            (progn
              (etaf-desktop-focus-window desktop window)
              (etaf-desktop--deactivate-other-instances
               (etaf-desktop--app-store desktop) id)
              (setf (etaf-desktop--instance-status instance) 'active)
              (etaf-desktop--instance-plist instance))
          (setf (etaf-desktop--instance-status instance) 'suspended)
          (etaf-desktop--instance-plist instance))))))

(defun etaf-desktop-suspend-instance (desktop id)
  "Minimize all windows of instance ID and mark it suspended."
  (let ((instance (etaf-desktop--instance desktop id)))
    (dolist (window-id (copy-sequence (etaf-desktop--instance-windows instance)))
      (when (condition-case nil (etaf-desktop-window-state desktop window-id)
              (etaf-desktop-error nil))
        (etaf-desktop-minimize-window desktop window-id)))
    (setf (etaf-desktop--instance-status instance) 'suspended)
    (etaf-desktop--instance-plist instance)))

(defun etaf-desktop-restore-instance (desktop id)
  "Restore all windows of instance ID and focus it."
  (let ((instance (etaf-desktop--instance desktop id)))
    (dolist (window-id (copy-sequence (etaf-desktop--instance-windows instance)))
      (when (condition-case nil (etaf-desktop-window-state desktop window-id)
              (etaf-desktop-error nil))
        (etaf-desktop-restore-window desktop window-id)))
    (etaf-desktop-focus-instance desktop id)))

(defun etaf-desktop-close-instance (desktop id &optional reason)
  "Close application instance ID and release its windows.
REASON is passed to the manifest close callback.  Callback failures are
recorded on the instance while all desktop windows are still released."
  (let* ((desktop (etaf-desktop--controller desktop))
         (instance (etaf-desktop--instance desktop id))
         (app (gethash (etaf-desktop--instance-app-id instance) etaf-desktop--apps))
         (callback-error nil))
    (unless (eq (etaf-desktop--instance-status instance) 'closed)
      (setf (etaf-desktop--instance-status instance) 'closing)
      (when (and app (etaf-desktop--app-close app))
        (condition-case err
            (funcall (etaf-desktop--app-close app)
                     (etaf-desktop--instance-context desktop instance)
                     (or reason 'close))
          (error (setq callback-error (error-message-string err)))))
      (dolist (window-id (copy-sequence (etaf-desktop--instance-windows instance)))
        (ignore-errors (etaf-desktop-close-window desktop window-id)))
      (setf (etaf-desktop--instance-status instance) (if callback-error 'error 'closed)
            (etaf-desktop--instance-error instance) callback-error))
    (etaf-desktop--instance-plist instance)))

(defun etaf-desktop--serialize-instance (desktop instance)
  "Return serializable state for INSTANCE."
  (let* ((app (gethash (etaf-desktop--instance-app-id instance) etaf-desktop--apps))
         (data (when (and app (etaf-desktop--app-serialize app))
                 (condition-case err
                     (funcall (etaf-desktop--app-serialize app)
                              (etaf-desktop--instance-context desktop instance))
                   (error (list :error (error-message-string err)))))))
    (list :id (etaf-desktop--instance-id instance)
          :app-id (etaf-desktop--instance-app-id instance)
          :status (etaf-desktop--instance-status instance)
          :options (copy-tree (etaf-desktop--instance-options instance))
          :state (copy-tree (etaf-desktop--instance-state instance))
          :data (copy-tree data)
          :windows (copy-sequence (etaf-desktop--instance-windows instance))
          :window-states
          (mapcar (lambda (id)
                    (cons id (condition-case nil
                                 (etaf-desktop-window-state desktop id)
                               (etaf-desktop-error nil))))
                  (etaf-desktop--instance-windows instance)))))

(defun etaf-desktop--session-layouts (desktop workspaces)
  "Return serializable layout policy for each WORKSPACE."
  (mapcar
   (lambda (workspace)
     (list :workspace workspace
           :mode (etaf-desktop-layout-mode desktop workspace)
           :tree (etaf-desktop-layout-tree desktop workspace)
           :floating (etaf-desktop-layout-floating-windows desktop workspace)))
   workspaces))

(defun etaf-desktop-session-state (desktop)
  "Return a serializable session plist for DESKTOP.
Application-owned data is obtained only through registered serialize
callbacks; View objects and Runtime internals are excluded."
  (let* ((desktop (etaf-desktop--controller desktop))
         (state (etaf-desktop-state desktop))
         (instances (mapcar (lambda (instance)
                              (etaf-desktop--serialize-instance desktop instance))
                            (hash-table-values
                             (etaf-desktop--app-store-instances
                              (etaf-desktop--app-store desktop))))))
    (list :version 1 :token (etaf-desktop--controller-token desktop)
          :desktop (copy-tree state)
          :layouts (etaf-desktop--session-layouts
                    desktop (plist-get state :workspaces))
          :instances instances)))

(defun etaf-desktop-save-session (desktop file)
  "Write `etaf-desktop-session-state' for DESKTOP to FILE and return FILE."
  (unless (stringp file) (etaf-desktop--fail "Session file must be a string: %S" file))
  (with-temp-file file
    (let ((print-level nil) (print-length nil))
      (prin1 (etaf-desktop-session-state desktop) (current-buffer))
      (insert "\n")))
  file)

(defun etaf-desktop--read-session (session-or-file)
  "Read SESSION-OR-FILE as a session plist."
  (if (and (stringp session-or-file) (file-readable-p session-or-file))
      (with-temp-buffer
        (insert-file-contents session-or-file)
        (read (current-buffer)))
    session-or-file))

(defun etaf-desktop--clear-apps (desktop)
  "Close all known app instances in DESKTOP."
  (let ((instances (etaf-desktop--app-store-instances
                    (etaf-desktop--app-store desktop))))
    (maphash (lambda (id _instance)
               (ignore-errors (etaf-desktop-close-instance desktop id 'restore)))
             (copy-hash-table instances))
    ;; Closed records belong to the old session and must not collide with
    ;; explicit instance IDs during the replacement restore.
    (clrhash instances)))

(defun etaf-desktop--clear-windows (desktop)
  "Close all remaining windows in DESKTOP."
  (dolist (window (etaf-desktop-windows desktop))
    (ignore-errors (etaf-desktop-close-window desktop (plist-get window :id)))))

(defun etaf-desktop--restore-workspaces (desktop workspaces)
  "Make DESKTOP's workspace keys exactly WORKSPACES when possible."
  (unless (and (listp workspaces) workspaces)
    (etaf-desktop--fail "Session has no valid workspaces"))
  (dolist (workspace workspaces)
    (unless (member workspace (plist-get (etaf-desktop-state desktop) :workspaces))
      (etaf-desktop-add-workspace desktop workspace)))
  (dolist (workspace (copy-sequence (plist-get (etaf-desktop-state desktop) :workspaces)))
    (when (and (not (member workspace workspaces))
               (> (length (plist-get (etaf-desktop-state desktop) :workspaces)) 1))
      (ignore-errors (etaf-desktop-remove-workspace desktop workspace))))
  (etaf-desktop-switch-workspace desktop (car workspaces)))

(defun etaf-desktop--restore-layouts (desktop layouts)
  "Restore serializable LAYOUTS after all windows have been recreated."
  (dolist (layout layouts)
    (let ((workspace (plist-get layout :workspace))
          (mode (plist-get layout :mode))
          (tree (plist-get layout :tree)))
      (when (and (member workspace
                         (plist-get (etaf-desktop-state desktop) :workspaces))
                 (memq mode '(floating tiling master-stack monocle)))
        ;; Application restore callbacks can legitimately return a different
        ;; set of windows.  Keep that app isolated while preserving every
        ;; valid workspace layout that can be reconstructed.
        (condition-case nil
            (progn
              (etaf-desktop-set-layout-mode desktop mode workspace)
              (etaf-desktop-layout-set-tree desktop tree workspace))
          (etaf-desktop-error nil))))))

(defun etaf-desktop-restore-session (desktop session-or-file)
  "Restore DESKTOP from a session plist or FILE and return its state.
Unknown applications become isolated error instances with a visible placeholder;
other applications continue restoring."
  (let* ((desktop (etaf-desktop--controller desktop))
         (session (etaf-desktop--read-session session-or-file))
         (saved-desktop (plist-get session :desktop))
         (saved-layouts (plist-get session :layouts))
         (saved-instances (plist-get session :instances)))
    (unless (and (listp session) (= (or (plist-get session :version) 0) 1)
                 (listp saved-desktop))
      (etaf-desktop--fail "Unsupported ETAF desktop session"))
    ;; Window IDs carry the desktop token, so a restored session keeps the
    ;; IDs it saved instead of addressing windows that no longer exist.
    (let ((token (plist-get session :token)))
      (when (and (stringp token) (not (string-empty-p token)))
        (setf (etaf-desktop--controller-token desktop) token)))
    (etaf-desktop--clear-apps desktop)
    (etaf-desktop--clear-windows desktop)
    (etaf-desktop--restore-workspaces desktop
                                      (plist-get saved-desktop :workspaces))
    ;; Settings are part of the serializable desktop value.  Apply them
    ;; through the public validator so an invalid preference cannot poison the
    ;; restored controller or bypass the layout policy.
    (dolist (key '(:theme :accent-color :layout-mode
                   :tile-outer-gap :tile-inner-gap :title-font-size
                   :content-font-size :font-family :drag-lock-modifier
                   :resize-enabled :confirm-close :taskbar-grouping
                   :keybindings))
      (when (plist-member (plist-get saved-desktop :settings) key)
        (etaf-desktop-set-setting
         desktop key (plist-get (plist-get saved-desktop :settings) key))))
    (dolist (saved saved-instances)
      (let* ((id (plist-get saved :id))
             (app-id (plist-get saved :app-id))
             (data (plist-get saved :data))
             (app (gethash app-id etaf-desktop--apps))
             (saved-window-states (plist-get saved :window-states))
             (saved-workspace (plist-get (cdr (car saved-window-states))
                                         :workspace)))
        (if app
            (progn
              (etaf-desktop-launch desktop app-id :instance-id id
                                   :options (plist-get saved :options)
                                   :restore-data data
                                   :restore t
                                   :workspace saved-workspace)
              (etaf-desktop-set-instance-state desktop id (plist-get saved :state))
              (dolist (pair (plist-get saved :window-states))
                (etaf-desktop--restore-window-state desktop (car pair)
                                                    (cdr pair)))
              (pcase (plist-get saved :status)
                ('suspended (etaf-desktop-suspend-instance desktop id))
                ('inactive
                 (setf (etaf-desktop--instance-status
                        (etaf-desktop--instance desktop id)) 'inactive))
                ('closed (etaf-desktop-close-instance desktop id 'restore))))
          (let ((instance (etaf-desktop--instance-create
                           :id id :app-id app-id :status 'error
                           :options (plist-get saved :options) :windows nil
                           :error (format "Application is not registered: %S" app-id)
                           :restore-data data)))
            (puthash id instance
                     (etaf-desktop--app-store-instances
                      (etaf-desktop--app-store desktop)))
            (etaf-desktop--placeholder desktop instance
                                        (etaf-desktop--instance-error instance))))))
    ;; Low-level windows opened without an application manifest remain usable
    ;; session members.  Their caller-owned View cannot be serialized, so
    ;; restore a visible title placeholder and the saved geometry.
    (let ((owned (cl-loop for instance in saved-instances
                          append (plist-get instance :windows))))
      (dolist (saved-window (plist-get saved-desktop :windows))
        (let ((id (plist-get saved-window :id)))
          (unless (member id owned)
            (ignore-errors
              (etaf-desktop-open-window
               desktop id
               :title (plist-get saved-window :title)
               :view (etaf-desktop--frame-body
                      (or (plist-get saved-window :title)
                          (format "%s" id)))
               :x (or (plist-get saved-window :x) 0)
               :y (or (plist-get saved-window :y) 0)
               :width (max (or (plist-get saved-window :width) 400)
                           (or (plist-get saved-window :min-width) 160))
               :height (max (or (plist-get saved-window :height) 12)
                            (or (plist-get saved-window :min-height) 3))
               :min-width (or (plist-get saved-window :min-width) 160)
               :min-height (or (plist-get saved-window :min-height) 3)
               :max-width (plist-get saved-window :max-width)
               :max-height (plist-get saved-window :max-height)
               :workspace (plist-get saved-window :workspace)
               :visible (if (plist-member saved-window :visible)
                            (plist-get saved-window :visible) t)
               :movable (if (plist-member saved-window :movable)
                            (plist-get saved-window :movable) t)
               :resizable (if (plist-member saved-window :resizable)
                              (plist-get saved-window :resizable) t))
              (etaf-desktop--restore-window-state desktop id saved-window))))))
    (etaf-desktop--restore-layouts desktop saved-layouts)
    ;; Restoring the policy can temporarily tile every recreated window.  Once
    ;; membership is final, restore the saved floating and maximized geometry;
    ;; ordinary tiles continue to use the allocator's current canvas.
    (dolist (window (plist-get saved-desktop :windows))
      (let ((id (plist-get window :id))
            (workspace (plist-get window :workspace)))
        (when (or (eq (etaf-desktop-layout-mode desktop workspace) 'floating)
                  (plist-get window :maximized)
                  (member id (etaf-desktop-layout-floating-windows desktop workspace)))
          (etaf-desktop--restore-window-state desktop id window))))
    (etaf-desktop-switch-workspace desktop (or (plist-get saved-desktop :active-workspace)
                                               (car (plist-get saved-desktop :workspaces))))
    (let ((saved-active (plist-get saved-desktop :active-window)))
      (when (and saved-active
                 (condition-case nil
                     (etaf-desktop-window-state desktop saved-active)
                   (etaf-desktop-error nil)))
        (etaf-desktop-focus-window desktop saved-active)))
    (etaf-desktop-state desktop)))

(provide 'etaf-desktop-apps)
;;; etaf-desktop-apps.el ends here
