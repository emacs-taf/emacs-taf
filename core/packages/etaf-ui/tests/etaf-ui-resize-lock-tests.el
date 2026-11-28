;;; etaf-ui-resize-lock-tests.el --- Native resize locking -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise public Components through their mounted native keymaps.  The
;; queued coordinates test gesture semantics, not physical pointer latency.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-ui)
(require 'ebox)

(defconst etaf-ui-resize-lock-test--edges
  '(left right top bottom top-left top-right bottom-left bottom-right))

(defun etaf-ui-resize-lock-test--run (component modifier ending)
  "Exercise COMPONENT's handles with MODIFIER and ENDING.
MODIFIER is a supported symbol, nil, or :default to omit the property.
ENDING is confirm, cancel or release.  Confirm must use the second press,
not later motion or release coordinates.  Cancel preserves subsequent input."
  (let ((last-input-event nil) (last-command-event nil)
        (buffer (generate-new-buffer " *etaf-ui-resize-lock*"))
        (refs (mapcar (lambda (edge) (cons edge (intern (format "resize-%s" edge))))
                      etaf-ui-resize-lock-test--edges))
        delivered)
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (etaf-mount
           buffer
           (etaf-node
            'box '(:position relative :width (px 400) :height (lh 20))
            (list
             (etaf-node
              component
              (append
               (list :width '(px 260) :height '(lh 12) :resize-refs refs
                     :on-resize (lambda (edge gesture)
                                  (push (list edge (plist-get gesture :phase)
                                              (plist-get gesture :delta)) delivered)))
               (unless (eq modifier :default) (list :drag-lock-modifier modifier))
               (when (eq component 'etaf-window) (list :title "Lock test")))
              (list "Body")))))
          (with-current-buffer buffer
            (let ((runtime (etaf-runtime-for-buffer buffer))
                  (window (selected-window)))
              (dolist (entry refs)
                (setq delivered nil)
                (let* ((position (etaf-host-ref-position runtime (cdr entry)))
                       (press-kind (if (eq modifier :default) 'S-down-mouse-1 's-down-mouse-1))
                       (release-kind (if (eq modifier :default) 'S-mouse-1 's-mouse-1))
                       (start (list window position '(2 . 2) 0))
                       (release (list window position '(3 . 2) 1))
                       (motion (list window position '(4 . 3) 2))
                       (finish (list window position '(5 . 4) 3))
                       (late (list window position '(6 . 5) 4))
                       (press (list press-kind start))
                       (command (key-binding (vector press) nil nil position))
                       (unread-command-events
                        (append
                         (list (list release-kind release))
                         (pcase ending
                           ('confirm (list (list 'mouse-movement motion)
                                           (list 'down-mouse-1 finish)
                                           (list 'mouse-movement late)
                                           (list 'mouse-1 late)))
                           ('cancel (list (list 'mouse-movement motion) 27)))
                         (list ?x))))
                  (should position)
                  (should (commandp command))
                  (funcall command press)
                  (should (equal unread-command-events '(?x)))
                  (should (cl-every (lambda (item) (eq (car item) (car entry))) delivered))
                  (let ((phases (mapcar #'cadr (reverse delivered))))
                    (should (equal phases
                                   (pcase ending
                                     ('confirm '(start move move end))
                                     ('cancel '(start move move cancel))
                                     ('release '(start end))))))
                  (when (eq ending 'confirm)
                    (should (equal (caddar delivered) '(3 . 2))))
                  (when (eq ending 'release)
                    (should (equal (caddar delivered) '(1 . 0))))
                  (should (etaf-host-ref-position runtime (cdr entry)))
                  (should-not (ebox-selector-query-buffer buffer ":active")))))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest etaf-ui-resize-lock-confirms-every-edge-and-corner ()
  "Window and standalone panel handles share Ebox's terminal-position contract."
  (etaf-ui-resize-lock-test--run 'etaf-window :default 'confirm)
  (etaf-ui-resize-lock-test--run 'etaf-window 'super 'confirm)
  (etaf-ui-resize-lock-test--run 'etaf-resizable-panel 'super 'confirm))

(ert-deftest etaf-ui-resize-lock-cancels-and-releases-active-targets ()
  "Escape cancels locked resize once without swallowing the next command."
  (etaf-ui-resize-lock-test--run 'etaf-window 'super 'cancel)
  (etaf-ui-resize-lock-test--run 'etaf-resizable-panel 'super 'cancel))

(ert-deftest etaf-ui-resize-lock-nil-keeps-ordinary-release ()
  "Explicit nil and a standalone panel's default end at the first release."
  (etaf-ui-resize-lock-test--run 'etaf-window nil 'release)
  (etaf-ui-resize-lock-test--run 'etaf-resizable-panel nil 'release)
  (etaf-ui-resize-lock-test--run 'etaf-resizable-panel :default 'release))

(ert-deftest etaf-ui-resize-lock-rejects-invalid-modifier ()
  "Unsupported modifiers fail at the public Component boundary."
  (dolist (component '(etaf-window etaf-resizable-panel))
    (should-error
     (etaf-render (etaf-node component '(:drag-lock-modifier invalid) nil))
     :type 'etaf-component-call-error)))

;;; etaf-ui-resize-lock-tests.el ends here
