;;; etaf-ui-affordance-tests.el --- Native control feedback -*- lexical-binding: t; -*-

;;; Commentary:
;; Check native feedback through supported component and rendering interfaces.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'etaf-ui)
(require 'ebox)

(ert-deftest etaf-ui-control-forwards-native-feedback ()
  "Native root attributes reach Ebox through the public Button component."
  (dolist (hover '(nil (:background-color "#abcdef")))
    (let* ((output (ebox-render
                    (etaf-render
                     (etaf-view
                      (box :hover-style '(:background-color "#123456")
                           (etaf-button :label "Custom" :pointer 'arrow :help-echo "Help"
                                        :hover-style hover))))))
           (position (string-match "Custom" output)))
      (should position)
      (should (eq 'arrow (get-text-property position 'pointer output)))
      (should (equal "Help" (get-text-property position 'help-echo output)))
      (if hover
          (should (string-match-p "#abcdef"
                                  (format "%S" (get-text-property position 'mouse-face output))))
        (should-not (get-text-property position 'mouse-face output))))))

(defconst etaf-ui-affordance-test--themes
  '((dark :ui-bg "#101216" :ui-fg "#E9ECF1" :ui-muted-fg "#98A0AC"
          :ui-accent "#5B8DEF" :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg "#1A2436"
          :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg "#3B6FD4"
          :ui-button-secondary-fg "#9CB8F0" :ui-button-secondary-bg "#1A2436"
          :ui-button-ghost-fg "#C7CDD6")
    (light :ui-bg "#FFFDF8" :ui-fg "#252A2E" :ui-muted-fg "#526174"
           :ui-accent "#2F6FE4" :ui-accent-fg "#FFFFFF" :ui-accent-soft-bg "#DCE7FA"
           :ui-button-primary-fg "#FFFFFF" :ui-button-primary-bg "#2F6FE4"
           :ui-button-secondary-fg "#1F4FB0" :ui-button-secondary-bg "#DCE7FA"
           :ui-button-ghost-fg "#252A2E"))
  "Application themes that name no hover color, one per palette.")

(defun etaf-ui-affordance-test--luminance (color)
  "Return COLOR's relative luminance, or nil when it is not #RRGGBB."
  (when (and (stringp color)
             (string-match
              "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'"
              color))
    (cl-loop for index in '(1 2 3)
             for weight in '(0.2126 0.7152 0.0722)
             for channel = (/ (string-to-number (match-string index color) 16) 255.0)
             sum (* weight (if (<= channel 0.03928)
                               (/ channel 12.92)
                             (expt (/ (+ channel 0.055) 1.055) 2.4))))))

(defun etaf-ui-affordance-test--contrast (one other)
  "Return the WCAG contrast ratio of colors ONE and OTHER."
  (let* ((first (etaf-ui-affordance-test--luminance one))
         (second (etaf-ui-affordance-test--luminance other))
         (high (max first second))
         (low (min first second)))
    (/ (+ high 0.05) (+ low 0.05))))

(etaf-define-component etaf-ui-affordance-test--themed-button (&key variant theme)
  "Render a Button inside THEME, which names no hover color."
  :setup (etaf-theme-provide theme)
  :render
  (etaf-view
   (etaf-button :ref 'button :variant variant :label "Action" :on-press #'ignore)))

(defun etaf-ui-affordance-test--hover-floor (surface contrast)
  "Return the contrast SURFACE lets a derived hover fill keep.
A surface already at the light or dark extreme cannot step away visibly,
so its visible step only has to clear the readable 4.5:1 floor."
  (let ((luminance (etaf-ui-affordance-test--luminance surface)))
    (if (or (null luminance) (<= luminance 0.02) (>= luminance 0.98))
        (min contrast 4.5)
      contrast)))

(ert-deftest etaf-ui-button-hover-keeps-text-readable ()
  "A Theme without hover tokens still hovers with a readable fill.
The catalog derives the fill from the application's own surface and text
colors: it moves away from the label, so light and dark palettes both keep
at least the resting contrast; a surface already at an extreme steps toward
the label but stays above 4.5:1.  One control must not reuse a fixed tint
across palettes."
  (let (summaries)
    (pcase-dolist (`(,mode . ,theme) etaf-ui-affordance-test--themes)
      (dolist (variant '(ghost secondary primary))
        (let ((fg (plist-get theme (pcase variant
                                     ('ghost :ui-button-ghost-fg)
                                     ('secondary :ui-button-secondary-fg)
                                     (_ :ui-button-primary-fg)))))
          (with-temp-buffer
            (unwind-protect
                (progn
                  (etaf-mount
                   (current-buffer)
                   (etaf-view (etaf-ui-affordance-test--themed-button :variant variant :theme theme)))
                  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
                         (props (etaf-runtime-host-props-for runtime 'button))
                         (hover (plist-get (plist-get props :hover-style) :background-color))
                         (surface (or (plist-get props :background-color)
                                      (plist-get theme :ui-bg)))
                         (rest (etaf-ui-affordance-test--contrast fg surface))
                         (hovered (etaf-ui-affordance-test--contrast fg hover)))
                    (should (stringp hover))
                    ;; The hover is a visible state, not the resting surface.
                    (should-not (equal hover surface))
                    ;; The label keeps its reading away from an extreme
                    ;; surface; an extreme surface still clears 4.5:1.
                    (should (>= hovered
                                (- (etaf-ui-affordance-test--hover-floor surface rest) 0.05)))
                    (push (cons (cons mode variant) hover) summaries)))
              (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer))))
                (etaf-unmount runtime)))))))
    (dolist (variant '(ghost secondary primary))
      (should-not (equal (alist-get (cons 'light variant) summaries nil nil #'equal)
                         (alist-get (cons 'dark variant) summaries nil nil #'equal))))))

(provide 'etaf-ui-affordance-tests)
;;; etaf-ui-affordance-tests.el ends here
