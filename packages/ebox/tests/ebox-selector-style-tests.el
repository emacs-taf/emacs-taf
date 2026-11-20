;;; ebox-selector-style-tests.el --- Ebox selector and cascade tests -*- lexical-binding: t; -*-

(require 'ebox-test-support)

(ert-deftest ebox-selector-query-finds-type-id-class-attribute-and-state ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "primary" :class "action hot"
                                  :attributes ((role . "button"))
                                  :states (selected)
                                  "Go")
                             (box :id "secondary" :class "action" "Stop")))
    (should (equal (ebox-selector-query root "box")
                   (list (car (ebox-selector-query root "#primary"))
                         (car (ebox-selector-query root "#secondary")))))
    (should (= (length (ebox-selector-query root ".action")) 2))
    (should (= (length (ebox-selector-query root ".hot:selected")) 1))
    (should (= (length (ebox-selector-query-buffer buffer "[role=button]")) 1))
    (should (equal (ebox-selector-query root "[id=\"primary\"] ")
                   (ebox-selector-query root "#primary")))
    (should (ebox-selector-match-node-p (car (ebox-selector-query root "#primary"))
                                        "#primary.hot:selected"))))

(ert-deftest ebox-node-set-states-updates-selector-matches-and-styles ()
  (ebox-test-with-mounted (buffer root
                           '(column :ecss (("#tab:active" :color "#ff0000"))
                                    (box :id "tab" "Tab")))
    (let ((tab (car (ebox-selector-query root "#tab"))))
      (should-not (ebox-selector-query root "#tab:active"))
      (ebox-node-set-states tab '(active))
      (should (equal (ebox-selector-query root "#tab:active") (list tab)))
      (should (equal (get-text-property (point-min) 'face)
                     '(:foreground "#ff0000")))
      (ebox-node-set-states tab nil)
      (should-not (ebox-selector-query root "#tab:active")))))

(ert-deftest ebox-inline-ecss-cascades-to-descendants ()
  (let* ((root (ebox-build
                '(column :ecss ((".accent" :color "#ff0000")
                                ("#plain" :color "#0000ff"))
                         (box :class "accent" "A")
                         (box :id "plain" "B"))))
         (rendered (ebox-render root)))
    (should (equal (substring-no-properties rendered) "A 
B "))
    (should (equal (get-text-property 0 'face rendered) '(:foreground "#ff0000")))
    (should (equal (get-text-property 3 'face rendered) '(:foreground "#0000ff")))))

(ert-deftest ebox-style-scope-membership-controls-rule-visibility ()
  (let* ((scope (ebox-style-scope-create '((".accent" :color "#ff0000"))))
         (root (ebox-build
                (list 'column :ecss-scope-roots (list scope)
                      (list 'box :class "accent" :ecss-scopes (list scope) "A")
                      '(box :class "accent" "B"))))
         (rendered (ebox-render root)))
    (should (equal (get-text-property 0 'face rendered) '(:foreground "#ff0000")))
    (should-not (get-text-property 3 'face rendered))))

(ert-deftest ebox-style-scope-with-rules-preserves-membership-identity ()
  (let* ((old (ebox-style-scope-create '((".accent" :color "#ff0000"))))
         (new (ebox-style-scope-with-rules old '((".accent" :color "#0000ff"))))
         (form (list 'column :ecss-scope-roots (list new)
                     (list 'box :class "accent" :ecss-scopes (list old) "A")))
         (rendered (ebox-render (ebox-build form))))
    (should (equal (get-text-property 0 'face rendered) '(:foreground "#0000ff")))))

(ert-deftest ebox-style-scope-create-rejects-invalid-rules-and-origins ()
  (should-error (ebox-style-scope-create '(("[" :color "#ff0000"))))
  (should-error (ebox-style-scope-create '(("&" :unknown t))))
  (should-error (ebox-style-scope-create nil :origin 'invalid)))

(ert-deftest ebox-inheritance-and-local-overrides-affect-faces ()
  (let* ((rendered (ebox-render
                    '(column :color "#111111"
                             (box "Inherited")
                             (box :color "#222222" "Local")))))
    (should (equal (get-text-property 0 'face rendered) '(:foreground "#111111")))
    (should (equal (get-text-property 11 'face rendered) '(:foreground "#222222")))))

(ert-deftest ebox-disabled-property-derives-disabled-selector-state ()
  (ebox-test-with-mounted (buffer root
                           '(column
                             (box :id "enabled" :tab-index 0 "Enabled")
                             (box :id "disabled" :tab-index 0 :disabled t "Disabled")))
    (should (= (length (ebox-selector-query root ":disabled")) 1))
    (should (equal (ebox-selector-query root "#disabled:disabled")
                   (ebox-selector-query-buffer buffer "#disabled:disabled")))
    (should-not (ebox-selector-query root "#enabled:disabled"))))

;;; ebox-selector-style-tests.el ends here
