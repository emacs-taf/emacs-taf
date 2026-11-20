;;; etaf-data-example.el --- Data Controller example -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This example owns a Data Controller at the Component boundary, stops it on
;; unmount, and keeps query, selection, and mutation on public Data APIs.

;;; Code:

(require 'etaf)

(defconst etaf-data-example-buffer-name "*ETAF Data Example*"
  "Buffer opened by `etaf-data-example-open'.")

(defconst etaf-data-example-tasks
  '((:id 1 :title "Define the public boundary" :owner "Ada" :status open)
    (:id 2 :title "Verify retained updates" :owner "Grace" :status done)
    (:id 3 :title "Document cleanup ownership" :owner "Alan" :status open)
    (:id 4 :title "Review visual hierarchy" :owner "Barbara" :status open)
    (:id 5 :title "Run the complete gate" :owner "Edsger" :status done))
  "Initial records used by the Data Controller example.")

(etaf-action-define etaf-data-example-add (runtime controller next-id)
  "Insert one task into CONTROLLER using NEXT-ID inside RUNTIME."
  (ignore runtime)
  (let ((identity (etaf-value next-id)))
    (etaf-data-mutate
     controller 'insert
     (list :id identity
           :title (format "Review example #%d" identity)
           :owner "Team"
           :status 'open))
    (etaf-set-value next-id (1+ identity))))

(etaf-action-define etaf-data-example-toggle (runtime controller identity)
  "Toggle IDENTITY selection in CONTROLLER inside RUNTIME."
  (ignore runtime)
  (etaf-data-select controller identity
                    (not (etaf-data-selected-p controller identity))))

(defun etaf-data-example--filter (controller query)
  "Set CONTROLLER to QUERY and load its matching records."
  (etaf-data-set-query controller query)
  (etaf-data-load controller))

(etaf-define-component etaf-data-example-row (&key controller task)
  "Render one retained TASK row from CONTROLLER."
  :view
  (flex :width '(px 718) :flex-flow '(row nowrap) :gap '((lh 0) (px 10))
        :padding '((lh 1) (px 12)) :border "#6D8A73"
        :bgcolor
        (if (etaf-value
             (etaf-data-selected-ref controller (plist-get task :id)))
            "#DCEBDD" "#FFFDF8")
        :role 'button :use (list (etaf-focusable))
        :on-press
        (lambda ()
          (etaf-dispatch 'etaf-data-example-toggle controller (plist-get task :id)))
    (box :width '(px 36) :font-weight 'bold
         :color
         (if (etaf-value
              (etaf-data-selected-ref controller (plist-get task :id)))
             "#2F6B43" "#8D887F")
     (text
      (expr
       (if (etaf-value
            (etaf-data-selected-ref controller (plist-get task :id)))
           "●" "○"))))
    (box :flex-grow 1 :flex-shrink 1 :flex-basis '(px 390)
         :min-width '(px 280)
     (text (expr (plist-get task :title))))
    (box :width '(px 96) :color "#66706A"
     (text (expr (plist-get task :owner))))
    (box :width '(px 84) :font-weight 'bold :text-align 'right
         :color (if (eq (plist-get task :status) 'done)
                    "#2F6B43" "#9B4A34")
     (text (expr (upcase (symbol-name (plist-get task :status))))))))

(etaf-define-component etaf-data-example-filter
    (&key controller label query border background)
  "Render one query filter for CONTROLLER."
  :view
  (box :padding '((lh 1) (px 12)) :border border :bgcolor background
       :font-weight 'bold :role 'button :use (list (etaf-focusable))
       :on-press
       (lambda () (etaf-data-example--filter controller query))
    (text (expr label))))

(etaf-define-component etaf-data-example-app ()
  "Render a memory-backed task application with owned cleanup."
  :bindings
  ((source (etaf-data-memory-source
            etaf-data-example-tasks :id-key :id
            :name 'etaf-data-example))
   (controller (etaf-data-controller
                source :page-size 20
                :name 'etaf-data-example))
   (next-id (etaf-ref 6 :name 'etaf-data-example-next-id)))
  :setup
  (progn
    (etaf-on-mounted (lambda () (etaf-data-load controller)))
    (etaf-on-unmounted (lambda () (etaf-data-stop controller))))
  :view
  (column :width '(px 720) :color "#252A2E" :bgcolor "#F8F5EE"
          (box :width '(px 720) :padding '((lh 1) (px 18)) :border "#8F432F"
               :bgcolor "#FFFDF8" :text-align 'center
               (column
                (text :color "#8F432F" :font-weight 'bold
                      "BEST PRACTICE  /  DATA OWNERSHIP")
                (text :font-weight 'bold "Task controller")
                (text :color "#66706A"
                      (expr
                       (format
                        "%d records · %d selected"
                        (etaf-value
                         (etaf-data-total controller))
                        (length
                         (etaf-value
                          (etaf-data-selection controller))))))))
          (box :height '(lh 1))
          (flex :width '(px 720) :flex-flow '(row wrap) :gap '((lh 1) (px 10))
                (etaf-data-example-filter
                 :ref 'data-filter-all
                 :controller controller
                 :label "ALL" :query nil :border "#4E7890" :background "#D9EAF2")
                (etaf-data-example-filter
                 :ref 'data-filter-open
                 :controller controller
                 :label "OPEN" :query '(:status open)
                 :border "#C97252" :background "#F1D4C9")
                (etaf-data-example-filter
                 :ref 'data-filter-done
                 :controller controller
                 :label "DONE" :query '(:status done)
                 :border "#6D8A73" :background "#DCEBDD")
                (box :padding '((lh 1) (px 12)) :border "#7A6B95" :bgcolor "#E7E2F1"
                     :font-weight 'bold :ref 'data-add :role 'button
                     :use (list (etaf-focusable))
                     :on-press
                     (lambda ()
                       (etaf-dispatch 'etaf-data-example-add controller next-id))
                     (text "+ ADD TASK")))
          (box :height '(lh 1))
          (column :width '(px 720)
                  (box :if
                       (null
                        (etaf-value
                         (etaf-data-items controller)))
                       :width '(px 720) :padding '((lh 2) (px 16))
                       :border "#8D887F" :bgcolor "#EEEAE2" :text-align 'center
                       (text "No matching tasks."))
                  (etaf-data-example-row
                   :for (task
                         (etaf-value
                          (etaf-data-items controller)))
                   :key (plist-get task :id)
                   :ref (intern (format "data-task-%d" (plist-get task :id)))
                   :controller controller
                   :task task))
          (box :height '(lh 1))
          (box :width '(px 720) :padding '((lh 1) (px 16)) :border "#8D887F"
               :color "#4D5651" :bgcolor "#EEEAE2"
               (text "Owner rule: create in setup, mutate through Data, stop on unmount"))))

;;;###autoload
(defun etaf-data-example-view ()
  "Return the Data Controller example View."
  (etaf-view (etaf-data-example-app)))

;;;###autoload
(defun etaf-data-example-open ()
  "Mount the Data Controller example and return its buffer."
  (interactive)
  (let ((buffer (etaf-mount etaf-data-example-buffer-name
                            (etaf-data-example-view))))
    (when (called-interactively-p 'interactive)
      (pop-to-buffer buffer))
    buffer))

;;;###autoload
(defun etaf-data-example-close ()
  "Unmount and kill the Data Controller example buffer."
  (interactive)
  (when-let* ((runtime
              (etaf-runtime-for-buffer etaf-data-example-buffer-name)))
    (etaf-unmount runtime))
  (when-let* ((buffer (get-buffer etaf-data-example-buffer-name)))
    (kill-buffer buffer)))

(provide 'etaf-data-example)

;;; etaf-data-example.el ends here
