;;; -*- lexical-binding: t; -*-
;;; etaf-ui-control-theme-tests.el --- Shared control Theme acceptance

(require 'ert)
(require 'cl-lib)
(require 'etaf-ui)

(etaf-define-component etaf-ui-control-theme-test--form (&key theme value press)
  "A form that derives its control geometry from THEME."
  :setup (etaf-theme-provide theme)
  :view
  (column :width '(ch 50)
    (etaf-button :ref 'action :label "Apply" :on-press press)
    (etaf-button :ref 'override :label "Compact"
                 :padding '((lh 0) (ch 1)) :border-radius '(px 2)
                 :border '((px 1) solid "#abcdef") :on-press press)
    (etaf-text-input :ref 'field :bind value :hide-label t :width '(ch 24))
    (etaf-text-input :ref 'plain :value "Plain" :variant 'plain :hide-label t)))

(defmacro etaf-ui-control-theme-test--with (&rest body)
  "Run BODY with a selected BUFFER, RUNTIME, THEME, VALUE and PRESSES."
  (declare (indent 0))
  `(let* ((buffer (generate-new-buffer " *control theme test*"))
          (theme (etaf-ref '(:ui-panel-bg "#182334" :ui-panel-fg "#eef2f7"
                             :ui-panel-border "#67788e" :ui-accent "#7da8f1")))
          (value (etaf-ref "60.183"))
          (presses 0)
          runtime)
     (unwind-protect
         (progn
           (etaf-mount buffer
                       (etaf-view
                        (etaf-ui-control-theme-test--form
                         :theme theme :value value :press (lambda () (cl-incf presses))))
                       '(:viewport-width 700 :viewport-height 30))
           (setq runtime (etaf-runtime-for-buffer buffer))
           (switch-to-buffer buffer)
           ,@body)
       (when-let* ((mounted (etaf-runtime-for-buffer buffer)))
         (etaf-unmount mounted))
       (kill-buffer buffer))))

(ert-deftest etaf-ui-control-theme-defaults-and-explicit-overrides ()
  "Absent tokens retain dark panel fallbacks; explicit props beat tokens."
  (etaf-ui-control-theme-test--with
    (let ((field (etaf-runtime-host-props-for runtime 'field))
          (action-size (etaf-host-ref-size runtime 'action)))
      (should (equal (plist-get field :background-color) "#182334"))
      (should (equal (plist-get field :border) '((px 1) solid "#67788e")))
      (should (= (cdr action-size) 1)))
    (setf (etaf-value theme)
          (append '(:ui-button-padding ((lh 1) (ch 2))
                    :ui-button-radius (px 7) :ui-button-border ((px 1) solid "#8798ae")
                    :ui-input-padding ((lh 1) (ch 2)) :ui-input-radius (px 7)
                    :ui-input-bg "#243449" :ui-input-border "#889cb5")
                  (etaf-value theme)))
    (let ((action (etaf-runtime-host-props-for runtime 'action))
          (override (etaf-runtime-host-props-for runtime 'override))
          (field (etaf-runtime-host-props-for runtime 'field))
          (plain (etaf-runtime-host-props-for runtime 'plain))
          (action-size (etaf-host-ref-size runtime 'action)))
      (should (= (cdr action-size) 3))
      (should (equal (plist-get action :padding) '((lh 1) (ch 2))))
      (should (equal (plist-get action :border-radius) '(px 7)))
      (should (equal (plist-get action :border) '((px 1) solid "#8798ae")))
      (should (equal (plist-get override :padding) '((lh 0) (ch 1))))
      (should (equal (plist-get override :border-radius) '(px 2)))
      (should (equal (plist-get override :border) '((px 1) solid "#abcdef")))
      (should (equal (plist-get field :padding) '((lh 1) (ch 2))))
      (should (equal (plist-get field :border-radius) '(px 7)))
      (should (equal (plist-get field :background-color) "#243449"))
      (should (equal (plist-get field :border) '((px 1) solid "#889cb5")))
      (should (equal (plist-get plain :padding) '((lh 0) (ch 0))))
      (should-not (plist-get plain :border))
      (should-not (plist-get plain :border-radius))
      (should-not (plist-get plain :background-color)))
    (etaf-focus runtime 'action)
    (execute-kbd-macro (kbd "RET"))
    (should (= presses 1))
    (should (equal (etaf-value value) "60.183"))))

(ert-deftest etaf-ui-control-theme-keeps-editing-and-focus-geometry ()
  "Palette changes keep an active native input and its reserved frame."
  (etaf-ui-control-theme-test--with
    (setf (etaf-value theme)
          (append '(:ui-input-padding ((lh 1) (ch 2)) :ui-input-radius (px 7)
                    :ui-input-bg "#243449" :ui-input-border "#889cb5")
                  (etaf-value theme)))
    (let ((size (etaf-host-ref-size runtime 'field)))
      (etaf-text-input-begin runtime 'field)
      (let ((focused (etaf-runtime-host-props-for runtime 'field))
            (focused-size (etaf-host-ref-size runtime 'field)))
        (should (equal (plist-get focused :border) '((px 1) solid "#7da8f1")))
        (should (equal focused-size size)))
      (execute-kbd-macro (kbd "C-a C-k"))
      (execute-kbd-macro "59.125")
      (should (equal (etaf-value value) "59.125"))
      (setf (etaf-value theme)
            '(:ui-input-padding ((lh 1) (ch 2)) :ui-input-radius (px 7)
              :ui-input-bg "#f8fafc" :ui-input-border "#b7c4d5"
              :ui-panel-fg "#263244" :ui-accent "#3b68b3"))
      (let ((active (and (etaf-text-input-active-p runtime) t))
            (focused-size (etaf-host-ref-size runtime 'field))
            (focused (etaf-runtime-host-props-for runtime 'field)))
        (should active)
        (should (equal focused-size size))
        (should (equal (plist-get focused :border) '((px 1) solid "#3b68b3")))
        (should (equal (plist-get focused :background-color) "#f8fafc")))
      (etaf-text-input-end)
      (let ((idle (etaf-runtime-host-props-for runtime 'field)))
        (should (equal (plist-get idle :border) '((px 1) solid "#b7c4d5"))))
      (should (equal (etaf-value value) "59.125")))
    (etaf-text-input-begin runtime 'field)
    (etaf-unmount runtime)
    (should-not (etaf-text-input-active-p))))

;;; etaf-ui-control-theme-tests.el ends here
