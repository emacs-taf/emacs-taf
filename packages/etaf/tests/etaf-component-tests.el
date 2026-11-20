;;; etaf-component-tests.el --- Component lifecycle and composition -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'etaf-test-support)

(defvar etaf-component-test-log nil
  "Lifecycle events recorded by the test Components.")

(etaf-define-component etaf-component-test-leaf (&key name)
  "Record NAME's lifecycle."
  :setup
  (progn
    (push (list 'setup name) etaf-component-test-log)
    (etaf-on-mounted (lambda () (push (list 'mounted name) etaf-component-test-log)))
    (etaf-on-updated (lambda () (push (list 'updated name) etaf-component-test-log)))
    (etaf-on-unmounted (lambda () (push (list 'unmounted name) etaf-component-test-log)))
    nil)
  :view (text (expr (format "leaf %s" name))))

(etaf-define-component etaf-component-test-parent (&key show)
  "Render a leaf while SHOW is non-nil."
  :setup (progn
           (etaf-on-mounted (lambda () (push '(mounted parent) etaf-component-test-log)))
           nil)
  :view
  (column
    (etaf-component-test-leaf :if (etaf-value show) :name 'child)
    (text "parent")))

(etaf-define-component etaf-component-test-tracked (&key value)
  "Derive a computed from tracked prop VALUE."
  :bindings ((doubled (let ((input (etaf-prop 'value)))
                        (etaf-computed (lambda () (* 2 (etaf-value input))))))
             (setups (etaf-ref 0)))
  :setup (etaf-update-value setups #'1+)
  :view (text (expr (format "%d doubled %d setup %d"
                            value (etaf-value doubled) (etaf-value setups)))))

(etaf-define-component etaf-component-test-validated (&key count)
  "Accept only integer COUNT."
  :validate (etaf-check-prop :count count (integerp count) "an integer")
  :view (text (expr (format "count %d" count))))

(etaf-define-component etaf-component-test-render (&key items)
  "Render ITEMS with the ordinary Elisp frontend."
  :render
  (etaf-view (column (text :for (item items) :key item (expr (format "* %s" item))))))

(etaf-define-component etaf-component-test-stateful ()
  "Expose setup state through `etaf-state'."
  :setup (list :greeting "hello")
  :view (text (expr (plist-get (etaf-state) :greeting))))

(etaf-define-component etaf-component-test-provider (&key value)
  "Provide VALUE to descendants."
  :setup (etaf-provide 'etaf-component-test-key value)
  :view (column (etaf-component-test-consumer) (slot)))

(etaf-define-component etaf-component-test-consumer ()
  "Show the injected value."
  :bindings ((value (etaf-inject 'etaf-component-test-key "missing")))
  :view (text (expr (format "injected %s"
                            (if (etaf-ref-p value) (etaf-value value) value)))))

(etaf-define-component etaf-component-test-watcher (&key source seen)
  "Record SOURCE, the injected Context and the Runtime into the cons SEEN."
  :setup
  (progn
    (etaf-watch-effect
     (lambda ()
       (setcar seen (list (etaf-value source)
                          (etaf-inject 'etaf-component-test-key "missing")
                          (and (etaf-current-runtime) t)))))
    nil)
  :view (text "watcher"))

(etaf-define-component etaf-component-test-watcher-provider (&key source seen)
  "Provide a context key around a child that watches SOURCE."
  :setup (etaf-provide 'etaf-component-test-key "provided")
  :view (etaf-component-test-watcher :source source :seen seen))

(etaf-define-component etaf-component-test-watch-source (&key source seen)
  "Record SOURCE through a two-argument `etaf-watch' callback into SEEN."
  :setup
  (progn
    (etaf-watch source
                (lambda (new _old)
                  (setcar seen (list new
                                     (etaf-inject 'etaf-component-test-key "missing")
                                     (and (etaf-current-runtime) t))))
                :immediate t)
    nil)
  :view (text "watcher"))

(etaf-define-component etaf-component-test-watch-provider (&key source seen)
  "Provide a context key around a child that watches SOURCE."
  :setup (etaf-provide 'etaf-component-test-key "provided")
  :view (etaf-component-test-watch-source :source source :seen seen))

(etaf-define-component etaf-component-test-computed-watcher (&key source seen)
  "Record SOURCE through a computed binding into SEEN."
  :bindings ((derived (etaf-computed
                       (lambda ()
                         (list (etaf-value source)
                               (etaf-inject 'etaf-component-test-key "missing")
                               (and (etaf-current-runtime) t)))
                       :test #'equal)))
  :setup
  (progn
    (etaf-watch derived (lambda (new _old) (setcar seen new)) :immediate t)
    nil)
  :view (text "computed watcher"))

(etaf-define-component etaf-component-test-computed-provider (&key source seen)
  "Provide a context key around a child that computes over SOURCE."
  :setup (etaf-provide 'etaf-component-test-key "provided")
  :view (etaf-component-test-computed-watcher :source source :seen seen))

(etaf-define-component etaf-component-test-themed ()
  "Paint with a theme token."
  :view (column (box :class "swatch" "swatch"))
  :styles ((".swatch" :color (etaf-theme-token :accent "#000000"))))

(etaf-define-component etaf-component-test-theme-root (&key theme)
  "Provide THEME to a themed child."
  :setup (etaf-theme-provide theme)
  :view (column (etaf-component-test-themed)))

(etaf-define-component etaf-component-test-mode (&key override)
  "Render the mode resolved for an OVERRIDE ref."
  :bindings ((mode (etaf-appearance-mode override)))
  :view (expr (format "mode:%s" (etaf-value mode))))

(etaf-define-component etaf-component-test-mode-host (&key appearance override)
  "Provide APPEARANCE to a mode reader with OVERRIDE."
  :setup (etaf-appearance-provide appearance)
  :view (column (etaf-component-test-mode :override override)))

(etaf-define-component etaf-component-test-appearance-root (&key appearance)
  "Provide APPEARANCE and render what a child reads."
  :setup (etaf-appearance-provide appearance)
  :view (column (expr (format "appearance:%s" (etaf-appearance)))))

(etaf-define-component etaf-component-test-hover-themed ()
  "Hover with a Theme token nested in a :hover-style plist."
  :view (column (box :ref 'hoverer :class "hoverer"
                     :hover-style (list :background-color
                                        (etaf-theme-token :tint "#DCE7FA"))
                     "hover")))

(etaf-define-component etaf-component-test-hover-root (&key theme)
  "Provide THEME to a hover token child."
  :setup (etaf-theme-provide theme)
  :view (column (etaf-component-test-hover-themed)))

(etaf-define-component etaf-component-test-local (&key on-ref)
  "Expose a local Host reference to ON-REF."
  :bindings ((target (etaf-local-ref 'target)))
  :setup (funcall on-ref target)
  :view (column (box :ref target :tab-index 0 "target")))

(etaf-define-component etaf-component-test-optional (&key mode)
  "Return nil, one View or a fragment depending on MODE."
  :bindings ((stamp (etaf-ref (random))))
  :render
  (pcase (etaf-value mode)
    ('none nil)
    ('one (etaf-view (text (expr (format "one %s" (numberp (etaf-value stamp)))))))
    (_ (etaf-view (fragment (text "first") (text "second"))))))

(ert-deftest etaf-component-lifecycle-hooks-run-in-order ()
  "Mounted hooks run children first; branch removal runs unmounted hooks."
  (setq etaf-component-test-log nil)
  (let ((show (etaf-ref t)))
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-parent :show show)))
      (should (equal (reverse etaf-component-test-log)
                     '((setup child) (mounted child) (mounted parent))))
      (setq etaf-component-test-log nil)
      (etaf-set-value show nil)
      (should (equal (etaf-test-lines) '("parent")))
      (should (member '(unmounted child) etaf-component-test-log))
      (setq etaf-component-test-log nil)
      (etaf-set-value show t)
      (should (equal (etaf-test-lines) '("leaf child" "parent")))
      (should (equal (reverse etaf-component-test-log) '((setup child) (mounted child))))
      (setq etaf-component-test-log nil)
      (etaf-unmount runtime)
      (should (member '(unmounted child) etaf-component-test-log)))))

(ert-deftest etaf-component-tracked-props-update-without-setup ()
  "`etaf-prop' tracks inputs while setup and bindings run once."
  (let ((value (etaf-ref 2)))
    (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-tracked
                                                        :value (etaf-value value)))))
      (should (equal (etaf-test-lines) '("2 doubled 4 setup 1")))
      (etaf-set-value value 5)
      (should (equal (etaf-test-lines) '("5 doubled 10 setup 1"))))))

(ert-deftest etaf-component-validation-rejects-invalid-input ()
  "Invalid props signal and keep the last accepted render."
  (let ((count (etaf-ref 1)))
    (should-error (etaf-render (etaf-view (etaf-component-test-validated :count "x"))))
    (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-validated
                                                        :count (etaf-value count)))))
      (should (equal (etaf-test-lines) '("count 1")))
      (should-error (etaf-set-value count 'bad))
      (should (equal (etaf-test-lines) '("count 1")))
      (etaf-set-value count 3)
      (should (equal (etaf-test-lines) '("count 3"))))))

(ert-deftest etaf-component-render-frontend-and-state ()
  "`:render' returns ordinary Views and setup state is readable."
  (let ((items (etaf-ref '(a b))))
    (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-render
                                                        :items (etaf-value items))
                                                       (etaf-component-test-stateful))))
      (should (equal (etaf-test-lines) '("* a" "* b" "hello")))
      (etaf-set-value items '(b c))
      (should (equal (etaf-test-lines) '("* b" "* c" "hello"))))))

(ert-deftest etaf-component-context-reaches-descendants ()
  "Provided values reach rendered descendants; slot content keeps caller Context."
  (let ((value (etaf-ref "one")))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-provider
                                                :value value
                                                (etaf-component-test-consumer))))
      (should (equal (etaf-test-lines) '("injected one" "injected missing")))
      (etaf-set-value value "two")
      (should (equal (etaf-test-lines) '("injected two" "injected missing")))))
  (etaf-test-with-mount (_runtime (etaf-view (column (etaf-component-test-consumer))))
    (should (equal (etaf-test-lines) '("injected missing")))))

(ert-deftest etaf-component-watcher-keeps-its-environment-on-rerun ()
  "A Component watcher keeps Context and Runtime on later reactive runs."
  (let* ((source (etaf-ref 1))
         (seen (cons nil nil)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-watcher-provider
                                                :source source :seen seen)))
      (should (equal (car seen) (list 1 "provided" t)))
      (etaf-set-value source 2)
      (should (equal (car seen) (list 2 "provided" t))))))

(ert-deftest etaf-component-watch-callback-keeps-its-environment ()
  "A two-argument `etaf-watch' callback keeps its environment when it reruns."
  (let* ((source (etaf-ref 1))
         (seen (cons nil nil)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-watch-provider
                                                :source source :seen seen)))
      (should (equal (car seen) (list 1 "provided" t)))
      (etaf-set-value source 2)
      (should (equal (car seen) (list 2 "provided" t))))))

(ert-deftest etaf-component-computed-keeps-its-environment-on-rerun ()
  "A computed keeps Context and Runtime when it refreshes outside rendering."
  (let* ((source (etaf-ref 1))
         (seen (cons nil nil)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-computed-provider
                                                :source source :seen seen)))
      (should (equal (car seen) (list 1 "provided" t)))
      ;; Refresh from a buffer without a Runtime, outside the Component
      ;; render that created the computed.
      (with-temp-buffer (etaf-set-value source 2))
      (should (equal (car seen) (list 2 "provided" t))))))

(ert-deftest etaf-component-theme-tokens-follow-provided-theme ()
  "Theme tokens in Component rules resolve from the provided Theme."
  (let ((theme (etaf-ref '(:accent "#FF0000"))))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-theme-root :theme theme)))
      (should (equal (etaf-test-face-attribute (etaf-test-face-at "swatch") :foreground)
                     "#FF0000"))
      (etaf-set-value theme '(:accent "#00FF00"))
      (should (equal (etaf-test-face-attribute (etaf-test-face-at "swatch") :foreground)
                     "#00FF00")))))

(ert-deftest etaf-component-appearance-follows-a-provided-ref ()
  "A Component reads the host appearance and re-renders when it switches."
  (let ((appearance (etaf-ref 'dark)))
    (etaf-test-with-mount (_runtime (etaf-view (etaf-component-test-appearance-root
                                                :appearance appearance)))
      (should (string-match-p "appearance:dark"
                              (buffer-substring-no-properties (point-min) (point-max))))
      (etaf-set-value appearance 'light)
      (should (string-match-p "appearance:light"
                              (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest etaf-component-mode-follows-the-host-unless-overridden ()
  "The resolved mode follows the host appearance and an override wins."
  (let ((appearance (etaf-ref 'dark))
        (override (etaf-ref nil)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (etaf-component-test-mode-host
                                       :appearance appearance :override override)))
      (should (string-match-p "mode:dark"
                              (buffer-substring-no-properties (point-min) (point-max))))
      (etaf-set-value appearance 'light)
      (should (string-match-p "mode:light"
                              (buffer-substring-no-properties (point-min) (point-max))))
      (etaf-set-value override 'dark)
      (should (string-match-p "mode:dark"
                              (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest etaf-theme-mode-re-derives-after-a-theme-switch ()
  "A Theme computed that follows the frame re-derives once per switch.
An application palette used to keep the mode the frame had when it was first
read, so a desktop or a game that followed the Emacs theme stayed on the old
palette after switching."
  (let* ((original (frame-parameter nil 'background-mode))
         (calls 0)
         (mode (etaf-computed (lambda () (cl-incf calls) (etaf-theme-current-mode)))))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'background-mode 'light)
          (should (eq 'light (etaf-value mode)))
          (should (= 1 calls))
          ;; A second read is served from the cache.
          (should (eq 'light (etaf-value mode)))
          (should (= 1 calls))
          (set-frame-parameter nil 'background-mode 'dark)
          (run-hooks 'enable-theme-functions)
          (sleep-for 0.05)
          (should (eq 'dark (etaf-value mode)))
          ;; One switch reaches the consumer once, not once per step.
          (should (= 2 calls)))
      (set-frame-parameter nil 'background-mode original)
      (run-hooks 'enable-theme-functions)
      (sleep-for 0.05))))

(ert-deftest etaf-component-rejects-an-invalid-appearance ()
  "Only light, dark, a ref or a computed is an appearance."
  (let ((error (should-error (etaf-appearance-provide 'sepia)
                             :type 'etaf-context-error)))
    (should (string-match-p "Appearance" (error-message-string error)))))

(etaf-define-component etaf-component-test-surface-declarer (&key standalone-log)
  "Declare the content surface on the nearest host."
  :bindings ((theme (etaf-ref (list :ui-bg "#101010" :ui-mode 'dark)))
             (mode (etaf-ref 'dark)))
  :setup (let ((surface (etaf-surface-host)))
           (if surface
               (etaf-surface-declare surface :theme theme :mode mode
                                     :modes '((light . "L") (dark . "D")))
             (when standalone-log
               (setcar standalone-log 'standalone))))
  :view (text (expr (format "mode:%s" (etaf-value mode)))))

(etaf-define-component etaf-component-test-surface-host (&key surface)
  "Provide SURFACE to a declarer below."
  :setup (etaf-surface-provide surface)
  :view (etaf-component-test-surface-declarer))

(ert-deftest etaf-surface-host-adopts-what-the-content-declares ()
  "A host reads the surface a mounted content declared.
The host does not guess: Theme, mode cell and mode labels are the content's,
so its chrome and the content's palette stay one state."
  (let ((surface (etaf-surface-create)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (etaf-component-test-surface-host
                                       :surface surface)))
      (should (equal '(:ui-bg "#101010" :ui-mode dark)
                     (etaf-value (etaf-surface-theme surface))))
      (should (eq 'dark (etaf-value (etaf-surface-mode surface))))
      (should (equal '((light . "L") (dark . "D"))
                     (etaf-surface-modes surface)))
      ;; The host's own switch writes the cell the content reads.
      (etaf-set-value (etaf-surface-mode surface) 'light)
      (should (string-match-p
               "mode:light"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest etaf-surface-declaration-needs-a-host ()
  "Without a host the content declares nothing and keeps painting itself."
  (let ((log (list nil)))
    (etaf-test-with-mount (_runtime
                           (etaf-view (etaf-component-test-surface-declarer
                                       :standalone-log log)))
      (should (equal '(standalone) log))
      (should (string-match-p
               "mode:dark"
               (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest etaf-surface-declare-rejects-values-it-cannot-frame ()
  "A surface declaration accepts only reactive Theme and mode sources."
  (let ((surface (etaf-surface-create)))
    (should-error (etaf-surface-provide 'surface) :type 'etaf-context-error)
    (should-error (etaf-surface-declare surface :theme '(:ui-bg "#000000"))
                  :type 'etaf-context-error)
    (should-error (etaf-surface-declare surface :mode 'dark)
                  :type 'etaf-context-error)
    (should-error (etaf-surface-declare surface :modes '((light)))
                  :type 'etaf-context-error)
    (should-error (etaf-surface-declare surface :modes '((light . 1)))
                  :type 'etaf-context-error)))

(ert-deftest etaf-component-hover-style-token-resolves-from-provided-theme ()
  "A token inside :hover-style resolves to the provided Theme colour.
Ebox turns the plist into a native mouse face; an unresolved token is an
invalid face attribute and the hover paint is lost."
  (let ((theme (etaf-ref '(:tint "#FF0000"))))
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-hover-root :theme theme)))
      (should (equal (plist-get (plist-get (etaf-runtime-host-props-for runtime 'hoverer)
                                           :hover-style)
                                :background-color)
                     "#FF0000"))
      (save-excursion
        (goto-char (point-min))
        (should (search-forward "hover" nil t))
        (should (equal (plist-get (get-text-property (match-beginning 0) 'mouse-face)
                                  :background)
                       "#FF0000")))
      (etaf-set-value theme '(:tint "#00FF00"))
      (should (equal (plist-get (plist-get (etaf-runtime-host-props-for runtime 'hoverer)
                                           :hover-style)
                                :background-color)
                     "#00FF00")))))

(ert-deftest etaf-component-local-ref-resolves-committed-host ()
  "A local Host reference supports focus and position queries."
  (let (target)
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-local
                                               :on-ref (lambda (ref) (setq target ref)))))
      (should target)
      (should (integerp (etaf-host-ref-position runtime target)))
      (etaf-focus runtime target)
      (should (equal (etaf-focused-host-ref runtime) target)))))

(ert-deftest etaf-component-output-shape-changes-keep-bindings ()
  "Output may switch between nil, one View and a fragment."
  (let ((mode (etaf-ref 'one)))
    (etaf-test-with-mount (_runtime (etaf-view (column (text "a")
                                                       (etaf-component-test-optional :mode mode)
                                                       (text "z"))))
      (should (equal (etaf-test-lines) '("a" "one t" "z")))
      (etaf-set-value mode 'none)
      (should (equal (etaf-test-lines) '("a" "z")))
      (etaf-set-value mode 'many)
      (should (equal (etaf-test-lines) '("a" "first" "second" "z")))
      (etaf-set-value mode 'one)
      (should (equal (etaf-test-lines) '("a" "one t" "z"))))))

(defvar etaf-component-test-rows-rendered nil
  "Labels rendered by the keyed-row test Components since the last reset.")

(etaf-define-component etaf-component-test-keyed-row (&key label)
  "Record that this row rendered LABEL, then show it."
  :render
  (progn
    (push label etaf-component-test-rows-rendered)
    (etaf-view (text (expr label)))))

(etaf-define-component etaf-component-test-keyed-rows (&key labels)
  "Render LABELS, a reactive source, as one keyed row Component each.
A row's key is its own label, so a row keeps its instance while the label
stays in the list and only a changed or added row renders."
  :render
  (etaf-node 'column nil
             (mapcar (lambda (label)
                       (etaf-node 'etaf-component-test-keyed-row
                                  (list :key label :label label)
                                  nil))
                     (etaf-value labels))))

(ert-deftest etaf-component-keyed-rows-repaint-one-row ()
  "A keyed list of Components re-renders only the row whose label changed.
The list Component re-renders whenever its input source changes; the row
instances are retained by key, so editing one row publishes that row's lines
and leaves the other instances, and their Hosts, alone.  A document preview
builds its per-block repaint on this boundary."
  (let ((labels (etaf-ref '("alpha" "beta" "gamma"))))
    (etaf-test-with-mount (runtime (etaf-view (etaf-component-test-keyed-rows
                                               :labels labels)))
      (should (equal '("alpha" "beta" "gamma") (etaf-test-lines)))
      ;; Every row rendered once at mount.
      (should (equal '("gamma" "beta" "alpha") etaf-component-test-rows-rendered))
      ;; Replacing the collection with an equal one changes no row.
      (setq etaf-component-test-rows-rendered nil)
      (etaf-set-value labels (list "alpha" "beta" "gamma"))
      (should-not etaf-component-test-rows-rendered)
      ;; Changing one label re-renders that row alone.
      (setq etaf-component-test-rows-rendered nil)
      (etaf-set-value labels (list "alpha" "beta edited" "gamma"))
      (should (equal '("beta edited") etaf-component-test-rows-rendered))
      (should (equal '("alpha" "beta edited" "gamma") (etaf-test-lines)))
      (let ((report (etaf-runtime-update-report runtime)))
        (should (eq 'lines (plist-get report :strategy)))
        (should (= 1 (plist-get report :edits))))
      ;; Inserting a row keeps every unchanged row's instance.
      (setq etaf-component-test-rows-rendered nil)
      (etaf-set-value labels (list "delta" "alpha" "beta edited" "gamma"))
      (should (equal '("delta") etaf-component-test-rows-rendered))
      (should (equal '("delta" "alpha" "beta edited" "gamma")
                     (etaf-test-lines))))))

(ert-deftest etaf-component-error-boundary-handles-errors ()
  "The error boundary returns the handler's value for signaled errors."
  (should (equal (etaf-error-boundary-run (lambda () (error "boom"))
                                          (lambda (err) (cadr err)))
                 "boom"))
  (should (= (etaf-error-boundary-run (lambda () 4) #'ignore) 4)))

(ert-deftest etaf-component-unknown-component-signals ()
  "Unknown Component tags are rejected at View construction."
  (should-error (etaf-node 'etaf-component-test-does-not-exist nil nil)))

(provide 'etaf-component-tests)

;;; etaf-component-tests.el ends here
