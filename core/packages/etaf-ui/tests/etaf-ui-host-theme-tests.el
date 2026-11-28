;;; -*- lexical-binding: t; -*-
;;; etaf-ui-host-theme-tests.el --- Host-adaptive theme engine acceptance tests

(require 'ert)
(require 'cl-lib)
(require 'ecss)
(require 'etaf-ui)

(ert-deftest etaf-ui-host-theme-wcag-and-oklch-calming ()
  "Dark and light palettes enforce WCAG AA legibility and calm neon accents."
  (let ((dark (etaf-ui-host-theme-palette
               :mode 'dark :bg "#191A1C" :fg "#E6EDF3" :accent "#00FFFF"
               :ok "#00FF00" :warn "#FFFF00" :danger "#FF0044"))
        (light (etaf-ui-host-theme-palette
                :mode 'light :bg "#FFFFFF" :fg "#1F2328" :accent "#88DDFF"
                :ok "#99EEAA" :warn "#FFEE66" :danger "#FFAABB")))
    (should (eq (plist-get dark :mode) 'dark))
    (should (plist-get dark :dark-p))
    (should (eq (plist-get light :mode) 'light))
    (should-not (plist-get light :dark-p))
    ;; Neon cyan on dark must be calmed below pure #00FFFF while staying legible.
    (should-not (string-equal-ignore-case (plist-get dark :accent) "#00FFFF"))
    (should-not (string-equal-ignore-case (plist-get dark :warn) "#FFFF00"))
    ;; Every text/semantic role passes WCAG AA >= 4.5 on surface-0 and surface-1.
    (dolist (p (list dark light))
      (let ((s0 (plist-get p :surface-0))
            (s1 (plist-get p :surface-1)))
        (should-not (string-equal-ignore-case s0 s1))
        (dolist (role '(:ink-1 :ink-2 :accent :ok :warn :danger :info :important))
          (let ((c (plist-get p role)))
            (should (string-match-p "\\`#[0-9a-fA-F]\\{6\\}\\'" c))
            (should (>= (etaf-ui-color-contrast c s0) 4.5))
            (should (>= (etaf-ui-color-contrast c s1) 4.5))))
        ;; accent-fg has strong contrast against accent fill.
        (should (>= (etaf-ui-color-contrast
                     (plist-get p :accent-fg) (plist-get p :accent))
                    4.5))))))

(ert-deftest etaf-ui-host-theme-curated-seeds-and-css-vars ()
  "Curated palettes preserve brand seeds, project UI tokens and ECSS `--etaf-*' vars."
  (let* ((pal (etaf-ui-host-theme-palette
               :mode 'dark :curated t
               :bg "#0B0E14" :fg "#ECF0F6" :surface-1 "#131720"
               :accent "#FB7299" :extras '(:brand-pink "#FB7299")))
         (tokens (etaf-ui-host-theme-tokens
                  :palette pal :overrides '(:ui-button-padding ((lh 0) (ch 2)))))
         (vars (etaf-ui-host-theme-css-vars :palette pal)))
    (should (equal (plist-get pal :surface-0) "#0B0E14"))
    (should (equal (plist-get pal :surface-1) "#131720"))
    (should (equal (plist-get pal :accent) "#FB7299"))
    (should (equal (plist-get pal :brand-pink) "#FB7299"))
    (should (equal (plist-get tokens :ui-bg) "#0B0E14"))
    (should (equal (plist-get tokens :ui-panel-bg) "#131720"))
    (should (equal (plist-get tokens :ui-accent) "#FB7299"))
    (should (equal (plist-get tokens :ui-button-padding) '((lh 0) (ch 2))))
    ;; Verify `--etaf-*' custom properties resolve cleanly via ECSS var().
    (should (equal (plist-get vars '--etaf-surface-0) "#0B0E14"))
    (should (equal (plist-get vars '--etaf-accent) "#FB7299"))
    (let* ((pkg (ecss-schema-package-create
                 'demo (list (list :id 'demo/color :initial "#000000"
                                   :impacts '(paint) :validator #'stringp))))
           (schemas (ecss-schema-set-compose pkg))
           (style (ecss-compute-style
                   schemas (ecss-subject-create :type 'box)
                   :declarations (append vars
                                         (list 'demo/color
                                               (ecss-var '--etaf-accent))))))
      (should (equal (ecss-computed-style-value style 'demo/color)
                     "#FB7299")))))

(ert-deftest etaf-ui-host-theme-ref-reacts-to-mode-and-theme-switch ()
  "Reactive host theme ref recomputes on `:mode-ref' writes and Emacs theme hooks."
  (let* ((mode-ref (etaf-ref 'light :name 'test-mode))
         (theme-ref (etaf-ui-host-theme-ref
                     :mode-ref mode-ref
                     :transform (lambda (p tokens)
                                  (append (list :custom-surface (plist-get p :surface-1))
                                          tokens))))
         (light-tokens (etaf-value theme-ref)))
    (should (equal (plist-get light-tokens :ui-bg) "#FFFFFF"))
    (should (stringp (plist-get light-tokens :custom-surface)))
    (setf (etaf-value mode-ref) 'dark)
    (let ((dark-tokens (etaf-value theme-ref)))
      (should (equal (plist-get dark-tokens :ui-bg) "#191A1C"))
      (should-not (equal (plist-get dark-tokens :custom-surface)
                         (plist-get light-tokens :custom-surface))))
    ;; Invalid options and non-function transform signal wrong-type-argument.
    (should-error (etaf-ui-host-theme-palette :bogus "#111111")
                  :type 'wrong-type-argument)
    (should-error (etaf-ui-host-theme-palette :mode 'invalid)
                  :type 'wrong-type-argument)
    (should-error (etaf-ui-host-theme-ref :transform 42)
                  :type 'wrong-type-argument)))

;;; etaf-ui-host-theme-tests.el ends here
