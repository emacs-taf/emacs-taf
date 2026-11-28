;;; etaf-ui-grid-composition-tests.el --- Shared table composition -*- lexical-binding: t; -*-

;;; Commentary:
;; DataGrid adapts Data onto ordinary keyed row Components.  Public rendering,
;; navigation and activation establish presentation and ownership behavior.

;;; Code:
(require 'ert)
(require 'etaf-ui)
(require 'ebox)

(defun etaf-ui-grid-composition-test--visible (text)
  "Return TEXT's visible content, geometry and paint."
  (list (substring-no-properties text)
        (cl-loop for position below (length text)
                 collect (list (get-text-property position 'face text)
                               (get-text-property position 'display text)))))

(ert-deftest etaf-ui-grid-and-table-share-row-presentation ()
  "Data rows keep their ordinary fields and share Table layout and selection."
  (let* ((rows '((:id 1 :name "Ada" :etaf-data-grid-state error :text "Business data")
                 (:id 2 :name "Lin")))
         (controller (etaf-data-controller
                      (etaf-data-memory-source rows :id-key :id) :auto-load t)))
    (unwind-protect
        (progn
          (etaf-data-select-one controller 1)
          (dolist (width '(12 (fr 1)))
            (let* ((columns (list (list :key :name :label "Name" :width width)))
                   (table (ebox-render (etaf-render
                           (etaf-view
                            (etaf-table :rows rows :columns columns
                                        :row-key (lambda (row) (plist-get row :id))
                                        :row-selected-p (lambda (row) (= (plist-get row :id) 1))
                                        :on-row-press #'ignore)))))
                   (grid (ebox-render (etaf-render
                          (etaf-view
                           (etaf-data-grid :controller controller :columns columns
                                           :row-key (lambda (row) (plist-get row :id))
                                           :on-row-press #'ignore))))))
              (should (string-match-p "Ada" grid))
              (should-not (string-match-p "Business data" grid))
              (should (equal (etaf-ui-grid-composition-test--visible table)
                             (etaf-ui-grid-composition-test--visible grid))))))
      (etaf-data-stop controller))))

(ert-deftest etaf-ui-grid-rows-use-framework-identity-and-callbacks ()
  "Two grids retain separate row targets and publish current callback inputs."
  (let* ((rows '((:id 1 :name "Ada") (:id 2 :name "Lin")))
         (controller
          (etaf-data-controller
           (etaf-data-source :load (lambda (&rest _args) (list :items rows)))
           :item-key (lambda (row) (plist-get row :id)) :auto-load t))
         picked
         (callback (etaf-ref (lambda (row) (setq picked (list 'left (plist-get row :name))))))
         (buffer (generate-new-buffer " *grid-composition*")))
    (unwind-protect
        (progn
          (etaf-mount
           buffer
           (etaf-view
            (column
              (etaf-data-grid
               :controller controller :columns '((:key :name :width 12))
               :row-key (lambda (row) (plist-get row :id))
               :on-row-press (etaf-value callback))
              (etaf-data-grid
               :controller controller :columns '((:key :name :width 12))
               :row-key (lambda (row) (plist-get row :id))
               :on-row-press (lambda (row) (setq picked (list 'right (plist-get row :name))))))))
          (let ((runtime (etaf-runtime-for-buffer buffer)) refs)
            ;; Each grid body is one Tab stop; Down moves between its rows.
            (with-current-buffer buffer
              (etaf-focus runtime)
              (dotimes (grid 2)
                (when (= grid 1) (etaf-focus-next runtime))
                (push (etaf-focused-host-ref runtime) refs)
                (call-interactively (key-binding (kbd "<down>") t))
                (push (etaf-focused-host-ref runtime) refs)))
            (setq refs (nreverse refs))
            (should (= 4 (length (delete-dups (copy-sequence refs)))))
            (etaf-focus runtime (car refs))
            (etaf-activate runtime)
            (should (equal picked '(left "Ada")))
            (setq rows '((:id 2 :name "Lin") (:id 1 :name "Ada updated")))
            (etaf-data-load controller)
            (should (equal (car refs) (etaf-focused-host-ref runtime)))
            (etaf-activate runtime)
            (should (equal picked '(left "Ada updated")))
            (setf (etaf-value callback)
                  (lambda (row) (setq picked (list 'updated (plist-get row :name)))))
            (etaf-activate runtime)
            (should (equal picked '(updated "Ada updated")))
            (etaf-focus runtime (nth 2 refs))
            (etaf-activate runtime)
            (should (equal picked '(right "Ada updated")))
            (setq rows '((:id 2 :name "Lin")))
            (etaf-data-load controller)
            (should-not (etaf-host-ref-position runtime (car refs)))
            (should-not (etaf-host-ref-position runtime (nth 2 refs)))
            (etaf-focus runtime (cadr refs))
            (etaf-activate runtime)
            (should (equal picked '(updated "Lin")))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (etaf-data-stop controller)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'etaf-ui-grid-composition-tests)
;;; etaf-ui-grid-composition-tests.el ends here
