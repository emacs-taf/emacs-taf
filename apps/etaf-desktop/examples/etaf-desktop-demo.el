;;; etaf-desktop-demo.el --- Standalone desktop with demo applications -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; M-x etaf-desktop-demo-open mounts one ETAF Desktop in a single buffer and
;; registers six everyday applications built only from public ETAF, ETAF UI
;; and ETAF Desktop interfaces: Notes, Tasks, Clock, Calculator, Chat and
;; Monitor.  Launch more instances from the application launcher, move and
;; resize them, switch layouts and workspaces, and exercise every shell
;; control against realistic window content.
;;
;; Every application is one ETAF Component wrapped in the shared
;; `etaf-desktop-demo-app' surface (header, body, footer toolbar) plus one
;; entry in `etaf-desktop-demo-apps' that supplies launcher metadata and the
;; default window geometry.  Add an application by defining a Component and
;; appending an entry; a Component owns its own state and lifecycle (see the
;; Clock timer), so the host needs no application-specific callbacks.
;;
;; From a checkout with sibling provider repositories:
;;
;;   cd etaf-desktop
;;   emacs -Q -L ../ecss -L ../ebox -L ../etaf -L ../etaf-ui -L . \
;;         -l examples/etaf-desktop-demo.el -f etaf-desktop-demo-open
;;
;; All displayed content is demonstration data.

;;; Code:
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-desktop)

(defvar etaf-desktop-demo--desktop nil
  "Controller owned by the most recent `etaf-desktop-demo-open'.")

;;;; Shared application surface

(defun etaf-desktop-demo--tint (key fallback)
  "Return the desktop theme color for KEY, or FALLBACK without a theme."
  (etaf-theme-token key fallback))

(etaf-define-component etaf-desktop-demo-app (&key title status)
  "Uniform window content: a TITLE/STATUS header, the default slot as body
and an optional `footer' slot rendered as a toolbar row.
TITLE and STATUS accept strings, refs or computeds; a `header' slot replaces
the title label."
  :render
  (let ((header (etaf-current-slot 'header))
        (footer (etaf-current-slot 'footer)))
    (etaf-view
     (flex :class "etaf-desktop-demo-app" :width 'stretch :height 'stretch
           :flex-direction 'column :align-items 'stretch
           ;; The desktop window is seamless: its resize strips cover the
           ;; frame's outermost body row and columns, so the application keeps
           ;; that margin clear for them instead of losing a control.
           :padding '((lh 0) (ch 2) (lh 1) (ch 2)) :row-gap '(lh 0)
       (expr
        (when (or header title status)
          (etaf-view
           (flex :class "etaf-desktop-demo-app-header" :width 'stretch
                 :flex-shrink 0 :justify-content 'space-between :align-items 'center
                 :column-gap '(ch 2)
             (expr (or header
                       (when title (etaf-view (etaf-label :text title :variant 'strong)))))
             (expr (when status
                     (etaf-view (etaf-label :text status :variant 'muted :wrap-mode 'none
                                            :flex-shrink 0 :min-width 'max-content))))))))
       (box :class "etaf-desktop-demo-app-body" :width 'stretch
            :height 'stretch :flex-grow 1 :flex-shrink 1 :flex-basis '(lh 0)
            :min-height '(lh 0) :overflow 'scroll
         (column :width 'stretch :item-gap '(lh 0)
           (expr (etaf-current-slot 'default))))
       (expr
        (when footer
          (etaf-view
           (row :class "etaf-desktop-demo-app-footer" :width 'stretch
                :flex-shrink 0 :item-gap '(ch 1) :cross-align 'center
             (expr footer)))))))))

;;;; Notes

(etaf-define-component etaf-desktop-demo-notes (&key (instance 1))
  "A note with an editable title, appendable lines and a live word count."
  :bindings ((title (etaf-ref (format "Note %s" instance)))
             (lines (etaf-ref '("Ideas worth keeping:"
                                "- desktop windows are ordinary ETAF views"
                                "- every control below is an ETAF UI component")))
             (words (etaf-computed
                     (lambda ()
                       (format "%d words"
                               (apply #'+ (mapcar (lambda (line) (length (split-string line)))
                                                  (etaf-value lines)))))))
             (add-line (lambda ()
                         (setf (etaf-value lines)
                               (append (etaf-value lines)
                                       (list (format "- line %d written at %s"
                                                     (1+ (length (etaf-value lines)))
                                                     (format-time-string "%H:%M"))))))))
  :view
  (etaf-desktop-demo-app :status words
    (slot :name 'header
      (etaf-text-input :bind title :label "Title" :hide-label t))
    (expr
     (if (etaf-value lines)
         (mapcar (lambda (line) (etaf-view (etaf-label :text line :wrap-mode 'word)))
                 (etaf-value lines))
       (etaf-view (etaf-empty :title "Empty note"
                              :description "Add a line to start writing."
                              :action-label "Add line" :on-action add-line))))
    (slot :name 'footer
      (etaf-button :label "Add line" :variant 'secondary :on-press add-line)
      (etaf-button :label "Clear" :variant 'ghost
                   :on-press (lambda () (setf (etaf-value lines) nil))))))

;;;; Tasks

(etaf-define-component etaf-desktop-demo-tasks ()
  "A checklist whose progress and summary follow the checked tasks."
  :bindings ((tasks (etaf-ref '((:key 1 :title "Review the tiled layout" :done t)
                                (:key 2 :title "Drag a window past the canvas edge")
                                (:key 3 :title "Open Settings and switch the theme")
                                (:key 4 :title "Launch a second Notes window"))))
             (next-key (etaf-ref 5))
             (done (etaf-computed
                    (lambda () (cl-count-if (lambda (task) (plist-get task :done))
                                            (etaf-value tasks)))))
             (total (etaf-computed (lambda () (max 1 (length (etaf-value tasks))))))
             (summary (etaf-computed
                       (lambda () (format "%d of %d done" (etaf-value done)
                                          (length (etaf-value tasks))))))
             (add-task (lambda ()
                         (let ((key (etaf-value next-key)))
                           (setf (etaf-value next-key) (1+ key)
                                 (etaf-value tasks)
                                 (append (etaf-value tasks)
                                         (list (list :key key :title (format "Task %d" key)))))))))
  :view
  (etaf-desktop-demo-app :title "Today" :status summary
    (etaf-progress :value done :max total)
    (box :height '(lh 1))
    (expr
     (if (etaf-value tasks)
         (mapcar
          (lambda (task)
            (let ((key (plist-get task :key)))
              (etaf-view
               (etaf-checkbox
                :key key :label (plist-get task :title)
                :checked (and (plist-get task :done) t)
                :on-change (lambda (checked)
                             (setf (etaf-value tasks)
                                   (mapcar (lambda (item)
                                             (if (eql (plist-get item :key) key)
                                                 (plist-put (copy-sequence item) :done checked)
                                               item))
                                           (etaf-value tasks))))))))
          (etaf-value tasks))
       (etaf-view (etaf-empty :title "All clear" :description "Nothing left to do."
                              :action-label "Add task" :on-action add-task))))
    (slot :name 'footer
      (etaf-button :label "Add task" :variant 'secondary :on-press add-task)
      (etaf-button :label "Clear done" :variant 'ghost
                   :on-press (lambda ()
                               (setf (etaf-value tasks)
                                     (cl-remove-if (lambda (task) (plist-get task :done))
                                                   (etaf-value tasks))))))))

;;;; Clock

(etaf-define-component etaf-desktop-demo-clock ()
  "The local time, refreshed every second while the window is mounted."
  :bindings ((time (etaf-ref (format-time-string "%H:%M:%S")))
             (date (etaf-ref (format-time-string "%A, %-d %B %Y")))
             (zone (format-time-string "%Z (UTC%z)"))
             (timer nil))
  :setup
  (progn
    (etaf-on-mounted
     (lambda ()
       (setq timer
             (run-at-time 1 1
                          (lambda ()
                            (etaf-call-with-batch
                             (lambda ()
                               (setf (etaf-value time) (format-time-string "%H:%M:%S")
                                     (etaf-value date)
                                     (format-time-string "%A, %-d %B %Y")))))))))
    (etaf-on-unmounted
     (lambda () (when timer (cancel-timer timer) (setq timer nil)))))
  :view
  (etaf-desktop-demo-app
    (column :width 'stretch :item-gap '(lh 0)
      (etaf-label :text time :variant 'heading :width 'stretch :text-align 'center)
      (etaf-label :text date :width 'stretch :text-align 'center)
      (etaf-label :text zone :variant 'muted :width 'stretch :text-align 'center))))

;;;; Calculator

(defun etaf-desktop-demo--calc-format (number)
  "Format NUMBER without a trailing `.0'."
  (if (and (floatp number) (= number (ffloor number)) (< (abs number) 1e15))
      (format "%d" (truncate number))
    (format "%s" number)))

(defun etaf-desktop-demo--calc-press (state key)
  "Return the calculator STATE plist after pressing KEY.
STATE holds :display, :accumulator, :operator and :fresh."
  (let ((display (plist-get state :display))
        (acc (plist-get state :accumulator))
        (op (plist-get state :operator))
        (fresh (plist-get state :fresh)))
    (cl-flet ((apply-op ()
                (let ((value (string-to-number display)))
                  (if (null op) value
                    (pcase op
                      ("+" (+ acc value)) ("−" (- acc value)) ("×" (* acc value))
                      ("÷" (if (zerop value) 0 (/ (float acc) value))))))))
      (pcase key
        ("C" (list :display "0" :accumulator nil :operator nil :fresh t))
        ("=" (list :display (etaf-desktop-demo--calc-format (apply-op))
                   :accumulator nil :operator nil :fresh t))
        ((or "+" "−" "×" "÷")
         (let ((value (apply-op)))
           (list :display (etaf-desktop-demo--calc-format value)
                 :accumulator value :operator key :fresh t)))
        ("." (if (string-search "." display) state
               (list :display (concat display ".") :accumulator acc :operator op :fresh nil)))
        (_ (list :display (if (or fresh (equal display "0")) key (concat display key))
                 :accumulator acc :operator op :fresh nil))))))

(defconst etaf-desktop-demo--calc-keys
  '("7" "8" "9" "÷" "4" "5" "6" "×" "1" "2" "3" "−" "C" "0" "." "+")
  "Calculator keypad in row-major order for a four-column grid.")

(etaf-define-component etaf-desktop-demo-calculator ()
  "A four-function calculator driven by a keypad grid."
  :bindings ((state (etaf-ref '(:display "0" :accumulator nil :operator nil :fresh t)))
             (display (etaf-computed (lambda () (plist-get (etaf-value state) :display))))
             (pending (etaf-computed
                       (lambda ()
                         (let ((current (etaf-value state)))
                           (if (plist-get current :operator)
                               (format "%s %s"
                                       (etaf-desktop-demo--calc-format
                                        (plist-get current :accumulator))
                                       (plist-get current :operator))
                             " ")))))
             (press (lambda (key)
                      (setf (etaf-value state)
                            (etaf-desktop-demo--calc-press (etaf-value state) key)))))
  :view
  (etaf-desktop-demo-app
    (column :class "etaf-desktop-demo-calc-display" :width 'stretch
            :padding '((lh 0) (ch 1)) :item-gap '(lh 0)
            :background-color (etaf-desktop-demo--tint :ui-accent-soft-bg "#D6E2FA")
            :color (etaf-desktop-demo--tint :ui-fg "#16202C")
      (etaf-label :text pending :variant 'muted :width 'stretch :text-align 'right)
      (etaf-label :text display :variant 'heading :width 'stretch :text-align 'right))
    (box :height '(lh 1))
    (grid :grid-template-columns '((ch 6) (ch 6) (ch 6) (ch 6))
          :column-gap '(ch 1) :row-gap '(lh 1)
      (expr
       (mapcar
        (lambda (key)
          (etaf-view
           (etaf-button :key key :label key :padding '((lh 0) (ch 2))
                        :variant (cond ((equal key "C") 'ghost)
                                       ((member key '("+" "−" "×" "÷")) 'primary)
                                       (t 'secondary))
                        :on-press (lambda () (funcall press key)))))
        etaf-desktop-demo--calc-keys))
      (box :grid-column-span 4 :width 'stretch
        (etaf-button :label "=" :padding '((lh 0) (ch 13))
                     :on-press (lambda () (funcall press "=")))))))

;;;; Chat

(defconst etaf-desktop-demo--replies
  '("Sounds good — the tiled layout keeps everything reachable."
    "Try dragging this window past the right edge."
    "Retained updates mean this reply arrived without a re-render."
    "Open Monitor to watch the Emacs heap while you type.")
  "Canned replies cycled by the Chat demo.")

(etaf-define-component etaf-desktop-demo-chat-bubble (&key from text)
  "One chat message aligned by its sender FROM."
  :render
  (let ((mine (equal from "You")))
    (etaf-view
     (flex :class "etaf-desktop-demo-chat-bubble" :width 'stretch
           :justify-content (if mine 'flex-end 'flex-start)
       (etaf-label :text text :wrap-mode 'word :max-width '(ch 44)
                   :padding '((lh 0) (ch 1))
                   :color (etaf-desktop-demo--tint :ui-fg "#16202C")
                   :background-color
                   (if mine
                       (etaf-desktop-demo--tint :ui-accent-soft-bg "#D6E2FA")
                     (etaf-desktop-demo--tint :ui-picker-item-bg "#F5F7FA")))))))

(etaf-define-component etaf-desktop-demo-chat ()
  "A two-party conversation that appends a canned reply on Send."
  :bindings ((messages (etaf-ref '((:key 1 :from "Mia" :text "Welcome to the ETAF Desktop demo.")
                                   (:key 2 :from "You" :text "Every window here is an app instance."))))
             (next-key (etaf-ref 3))
             (draft (etaf-ref ""))
             (count (etaf-computed
                     (lambda () (format "%d messages" (length (etaf-value messages))))))
             (send (lambda ()
                     (let* ((key (etaf-value next-key))
                            (text (if (string-empty-p (etaf-value draft))
                                      (format "Message %d" key)
                                    (etaf-value draft)))
                            (reply (nth (mod key (length etaf-desktop-demo--replies))
                                        etaf-desktop-demo--replies)))
                       (setf (etaf-value messages)
                             (append (etaf-value messages)
                                     (list (list :key key :from "You" :text text)
                                           (list :key (1+ key) :from "Mia" :text reply)))
                             (etaf-value next-key) (+ key 2)
                             (etaf-value draft) "")))))
  :view
  (etaf-desktop-demo-app :title "Mia" :status count
    (column :width 'stretch :item-gap '(lh 1)
      (expr
       (mapcar
        (lambda (message)
          (etaf-view
           (etaf-desktop-demo-chat-bubble :key (plist-get message :key)
                                          :from (plist-get message :from)
                                          :text (plist-get message :text))))
        (last (etaf-value messages) 6))))
    (slot :name 'footer
      ;; The input's root stretches; a max-content box keeps Send beside it.
      (box :width 'max-content
        (etaf-text-input :bind draft :label "Message"
                         :placeholder "Type a message…" :hide-label t))
      (etaf-button :label "Send" :on-press send))))

;;;; Monitor

(defun etaf-desktop-demo--monitor-sample ()
  "Return a plist of Emacs runtime figures for the Monitor window."
  (list :buffers (format "%d" (length (buffer-list)))
        :gcs (format "%d" gcs-done)
        :gc-time (format "%.1f s" gc-elapsed)
        :uptime (format-seconds "%hh %mm %ss" (float-time (time-since before-init-time)))
        :taken (format "sampled %s" (format-time-string "%H:%M:%S"))))

(etaf-define-component etaf-desktop-demo-monitor ()
  "Emacs runtime statistics refreshed on demand."
  :bindings ((sample (etaf-ref (etaf-desktop-demo--monitor-sample)))
             (field (lambda (key)
                      (etaf-computed (lambda () (plist-get (etaf-value sample) key)))))
             (buffers (funcall field :buffers))
             (gcs (funcall field :gcs))
             (gc-time (funcall field :gc-time))
             (uptime (funcall field :uptime))
             (taken (funcall field :taken)))
  :view
  (etaf-desktop-demo-app :title "Emacs runtime" :status taken
    (grid :grid-template-columns '((fr 1) (fr 1)) :column-gap '(ch 2) :row-gap '(lh 1)
      (etaf-statistic :label "Buffers" :value buffers :trend "live")
      (etaf-statistic :label "Garbage collections" :value gcs :trend "since start")
      (etaf-statistic :label "GC time" :value gc-time :trend "total")
      (etaf-statistic :label "Uptime" :value uptime :trend "this session"))
    (slot :name 'footer
      (etaf-button :label "Refresh" :variant 'secondary
                   :on-press (lambda ()
                               (setf (etaf-value sample) (etaf-desktop-demo--monitor-sample)))))))

;;;; Application manifests

(defun etaf-desktop-demo--notes-props (context)
  "Return Notes props for CONTEXT: the instance number from its id."
  (list :instance (car (last (split-string (plist-get context :instance-id) "-")))))

(defconst etaf-desktop-demo-apps
  '((etaf-desktop-demo-notes
     :title "Notes" :icon "N" :capabilities (multiple-instances resizable)
     :props etaf-desktop-demo--notes-props
     :window (:x 24 :y 1 :width 480 :height 15 :min-width 300 :min-height 9))
    (etaf-desktop-demo-tasks
     :title "Tasks" :icon "T" :capabilities (resizable)
     :window (:x 528 :y 1 :width 400 :height 15 :min-width 300 :min-height 9))
    (etaf-desktop-demo-clock
     :title "Clock" :icon "C" :capabilities (multiple-instances resizable)
     :window (:x 952 :y 1 :width 360 :height 8 :min-width 260 :min-height 7))
    (etaf-desktop-demo-chat
     :title "Chat" :icon "@" :capabilities (resizable)
     :window (:x 24 :y 18 :width 560 :height 17 :min-width 340 :min-height 10))
    (etaf-desktop-demo-monitor
     :title "Monitor" :icon "M" :capabilities (resizable)
     :window (:x 24 :y 1 :width 520 :height 16 :min-width 340 :min-height 13))
    (etaf-desktop-demo-calculator
     :title "Calculator" :icon "=" :capabilities (multiple-instances)
     :window (:x 568 :y 1 :width 300 :height 17 :min-width 300 :min-height 17
              :resizable nil)))
  "Demo application manifests keyed by their Component symbol.
Each value holds the launcher :title and :icon, the manifest :capabilities,
an optional :props function of the open context returning Component props,
and the :window geometry passed to `etaf-desktop-open-window'.")

(defconst etaf-desktop-demo-layout
  '((main etaf-desktop-demo-notes etaf-desktop-demo-tasks
          etaf-desktop-demo-clock etaf-desktop-demo-chat)
    (work etaf-desktop-demo-monitor etaf-desktop-demo-calculator))
  "Applications launched on each workspace when the demo opens.")

(defun etaf-desktop-demo--cascade (context)
  "Return a (PIXELS . ROWS) offset so repeated instances of one app stagger."
  (let* ((app-id (plist-get context :app-id))
         (id (plist-get context :instance-id))
         (siblings (cl-count-if
                    (lambda (instance)
                      (and (eq (plist-get instance :app-id) app-id)
                           (not (equal (plist-get instance :id) id))
                           (not (memq (plist-get instance :status) '(closing closed error)))))
                    (etaf-desktop-instances (plist-get context :desktop))))
         (step (mod siblings 6)))
    (cons (* step 48) (* step 2))))

(defun etaf-desktop-demo--open (component manifest context)
  "Open COMPONENT's window for MANIFEST in the launch CONTEXT."
  (let* ((props (when-let* ((props-fn (plist-get manifest :props)))
                  (funcall props-fn context)))
         (window (copy-sequence (plist-get manifest :window)))
         (offset (etaf-desktop-demo--cascade context)))
    (list :windows
          (list (append (list :id "main" :title (plist-get manifest :title)
                              :x (+ (plist-get window :x) (car offset))
                              :y (+ (plist-get window :y) (cdr offset))
                              :view (etaf-node component props nil))
                        window)))))

(defun etaf-desktop-demo--register-apps ()
  "Register every manifest in `etaf-desktop-demo-apps', replacing idle copies."
  (pcase-dolist (`(,component . ,manifest) etaf-desktop-demo-apps)
    (etaf-desktop-register-app
     component
     :title (plist-get manifest :title) :icon (plist-get manifest :icon)
     :capabilities (plist-get manifest :capabilities)
     :open (lambda (context) (etaf-desktop-demo--open component manifest context))
     :replace t)))

;;;###autoload
(defun etaf-desktop-demo-open (&optional buffer-or-name)
  "Mount the demo desktop with its applications and return the controller.
BUFFER-OR-NAME names the target buffer; it defaults to *ETAF Desktop Demo*.
Reopening closes the previous demo desktop first.  Interactive calls display
the mounted buffer."
  (interactive)
  (when etaf-desktop-demo--desktop
    (ignore-errors (etaf-desktop-close etaf-desktop-demo--desktop)))
  (etaf-desktop-demo--register-apps)
  (let ((desktop (etaf-desktop-create :name (or buffer-or-name "*ETAF Desktop Demo*")
                                      :workspaces (mapcar #'car etaf-desktop-demo-layout))))
    (setq etaf-desktop-demo--desktop desktop)
    (pcase-dolist (`(,workspace . ,apps) etaf-desktop-demo-layout)
      (dolist (app apps)
        (etaf-desktop-launch desktop app :workspace workspace)))
    (etaf-desktop-switch-workspace desktop (car (car etaf-desktop-demo-layout)))
    (let ((buffer (etaf-desktop-mount desktop)))
      (when (called-interactively-p 'interactive) (switch-to-buffer buffer)))
    desktop))

(provide 'etaf-desktop-demo)
;;; etaf-desktop-demo.el ends here
