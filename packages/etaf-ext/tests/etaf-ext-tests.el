;;; etaf-ext-tests.el --- Public API acceptance tests for etaf-ext -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public API acceptance scenarios for the pure `etaf-ext' engine:
;; manifest validation, matching & per-app policies, strict permission gating,
;; isolated SQLite WAL storage, shared tree caching, circuit breaker & Pure Mode,
;; multi-extension coexistence (decorate + companion + overlay + key layers),
;; and the interactive Extension Manager UI (`etaf-ext-manage').

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'etaf)
(require 'etaf-ui)
(require 'etaf-ext)

(defun etaf-ext-test--mount (buf view &optional options)
  "Mount VIEW into BUF with OPTIONS and return its live `etaf-runtime'."
  (etaf-mount buf view options)
  (etaf-runtime-for-buffer buf))

(defun etaf-ext-test--buf-text (runtime)
  "Return plain text of RUNTIME's mounted buffer without text properties."
  (with-current-buffer (etaf-runtime-buffer runtime)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-ext-test--find-text-host (tree substr)
  "Return first text Host ID in TREE whose `:text' contains SUBSTR."
  (let ((found nil))
    (cl-labels ((walk (node)
                  (when (and (not found) (listp node))
                    (when (and (eq (plist-get node :tag) 'text)
                               (stringp (plist-get node :text))
                               (string-search substr (plist-get node :text)))
                      (setq found (plist-get node :id)))
                    (dolist (c (plist-get node :children)) (walk c)))))
      (dolist (r tree) (walk r)))
    found))

(defmacro etaf-ext-test--with-env (db-var &rest body)
  "Run BODY with an isolated temporary storage file and clean `etaf-ext-mode'."
  (declare (indent 1))
  `(let* ((,db-var (make-temp-file "etaf-ext-test-" nil ".sqlite3"))
          (etaf-ext-storage-file ,db-var)
          (etaf-ext-use-posframe nil)
          (etaf-ext-circuit-breaker-threshold 3)
          (orig-mode (bound-and-true-p etaf-ext-mode)))
     (unwind-protect
         (progn
           (etaf-ext-mode 1)
           ,@body)
       (etaf-ext-mode (if orig-mode 1 -1))
       (dolist (f (list ,db-var
                        (concat ,db-var "-wal")
                        (concat ,db-var "-shm")))
         (when (file-exists-p f)
           (ignore-errors (delete-file f)))))))

;;;; 1. Manifest validation, matching and per-app policies

(ert-deftest etaf-ext-manifest-validation-matching-and-per-app-policies ()
  (etaf-ext-test--with-env _db
    (should-error (etaf-ext-register nil :name "bad") :type 'etaf-ext-error)
    (should-error (etaf-ext-register 'test-bad-perm :permissions '(not-a-perm))
                  :type 'etaf-ext-error)
    (should-error (etaf-ext-register 'test-bad-act :activation 'never)
                  :type 'etaf-ext-error)
    (let* ((attached-uris nil)
           (buf (generate-new-buffer " *etaf-ext-match-test*"))
           (app-ref (etaf-ref 'demo-reader))
           (kind-ref (etaf-ref 'document))
           (uri-ref (etaf-ref "https://docs.example.org/a"))
           (rt nil))
      (unwind-protect
          (progn
            (etaf-ext-define test-match-ext
              :name "Match Probe"
              :version "1.0.0"
              :activation 'on-match
              :matches '(:apps (demo-reader) :kinds (document)
                               :uri-regexp "docs\\.example\\.org")
              :priority 35
              :permissions '(read-tree)
              :on-attach (lambda (ctx)
                           (push (plist-get (etaf-ext-ctx-meta ctx) :uri)
                                 attached-uris)))
            (setq rt (etaf-ext-test--mount
                      buf
                      (etaf-node 'column '(:width (ch 60))
                                 (list (etaf-node 'text nil '("Sample doc body."))))
                      (list :viewport-width 480 :viewport-height 20
                            :meta (list :app app-ref :kind kind-ref :uri uri-ref))))
            (should (etaf-ext-match-p 'test-match-ext rt))
            (should (memq 'test-match-ext (etaf-ext-active-for-runtime rt)))
            (should (etaf-ext-context 'test-match-ext rt))
            (should (equal attached-uris '("https://docs.example.org/a")))
            ;; Reactive meta update to non-matching app detaches automatically
            (etaf-call-with-batch
             (lambda ()
               (etaf-set-value app-ref 'other-app)
               (etaf-set-value kind-ref 'tool)
               (etaf-set-value uri-ref "https://other.org/")))
            (should-not (memq 'test-match-ext (etaf-ext-active-for-runtime rt)))
            (should-not (etaf-ext-context 'test-match-ext rt))
            ;; Explicit per-app allow overrides :matches
            (etaf-ext-set-app-policy 'test-match-ext 'other-app 'allow)
            (should (eq (etaf-ext-app-policy 'test-match-ext 'other-app) 'allow))
            (should (memq 'test-match-ext (etaf-ext-active-for-runtime rt)))
            ;; Explicit per-app deny detaches cleanly
            (etaf-ext-set-app-policy 'test-match-ext 'other-app 'deny)
            (should (eq (etaf-ext-app-policy 'test-match-ext 'other-app) 'deny))
            (should-not (memq 'test-match-ext (etaf-ext-active-for-runtime rt)))
            ;; Clear policy
            (etaf-ext-set-app-policy 'test-match-ext 'other-app nil)
            (should-not (etaf-ext-app-policy 'test-match-ext 'other-app)))
        (etaf-ext-unregister 'test-match-ext)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; 2. Strict permission gating

(ert-deftest etaf-ext-strict-permission-gating-on-context-primitives ()
  (etaf-ext-test--with-env _db
    (let* ((buf (generate-new-buffer " *etaf-ext-perm-test*"))
           (rt nil))
      (unwind-protect
          (progn
            (etaf-ext-define test-zero-perm
              :name "Zero Perms"
              :activation 'on-command
              :permissions '())
            (setq rt (etaf-ext-test--mount
                      buf
                      (etaf-node 'column '(:width (ch 50))
                                 (list (etaf-node 'text nil '("Protected text."))))
                      '(:viewport-width 400 :viewport-height 16)))
            (let ((ctx (etaf-ext-attach 'test-zero-perm rt)))
              (should ctx)
              (should-error (etaf-ext-tree ctx) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-geometries ctx '(1)) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-host-at-point ctx) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-host-text-at-point ctx) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-inspect-host ctx 1) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-commit-summary ctx) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-decorate ctx nil) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-companion ctx nil) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-override ctx nil) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-present ctx '((1 . (:mode override :text "x"))))
                            :type 'etaf-ext-permission-error)
              (should (eq (etaf-ext-ctx-trigger ctx) 'manual))
              (should (etaf-ext-refresh-badge ctx))
              (should-error (etaf-ext-set-overlay ctx (etaf-node 'text nil '("x")))
                            :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-press ctx 1) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-focus ctx 1) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-scroll-to ctx 1) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-storage-get ctx "k") :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-storage-set ctx "k" 1) :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-show-popup ctx (etaf-node 'text nil '("p")))
                            :type 'etaf-ext-permission-error)
              (should-error (etaf-ext-notify ctx "hi") :type 'etaf-ext-permission-error)))
        (etaf-ext-unregister 'test-zero-perm)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; 3. Isolated SQLite WAL storage and in-memory fallback

(ert-deftest etaf-ext-isolated-sqlite-storage-and-memory-fallback ()
  (etaf-ext-test--with-env db
    (let* ((buf (generate-new-buffer " *etaf-ext-store-test*"))
           (rt nil))
      (unwind-protect
          (progn
            (etaf-ext-define test-store-a :activation 'on-command :permissions '(storage))
            (etaf-ext-define test-store-b :activation 'on-command :permissions '(storage))
            (setq rt (etaf-ext-test--mount
                      buf
                      (etaf-node 'text nil '("Store test"))
                      '(:viewport-width 320 :viewport-height 10)))
            (let ((ctx-a (etaf-ext-attach 'test-store-a rt))
                  (ctx-b (etaf-ext-attach 'test-store-b rt)))
              (etaf-ext-storage-set ctx-a "theme" 'solarized)
              (etaf-ext-storage-set ctx-b "theme" 'nord)
              (should (eq (etaf-ext-storage-get ctx-a "theme") 'solarized))
              (should (eq (etaf-ext-storage-get ctx-b "theme") 'nord))
              (should (equal (etaf-ext-storage-keys ctx-a) '("theme")))
              (should (eq (etaf-ext-storage-get ctx-a "missing" 'fallback) 'fallback))
              (should (etaf-ext-storage-delete ctx-a "theme"))
              (should (null (etaf-ext-storage-keys ctx-a)))
              (should (eq (etaf-ext-storage-get ctx-b "theme") 'nord))
              (let ((etaf-ext-storage-file nil))
                (etaf-ext-storage-set ctx-a "mem-k" '(1 2 3))
                (should (equal (etaf-ext-storage-get ctx-a "mem-k") '(1 2 3)))
                (should (etaf-ext-storage-delete ctx-a "mem-k"))))
            (when (and (fboundp 'sqlite-available-p) (sqlite-available-p))
              (should (file-exists-p db))))
        (etaf-ext-unregister 'test-store-a)
        (etaf-ext-unregister 'test-store-b)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; 4. Shared tree cache, circuit breaker isolation and Pure Mode

(ert-deftest etaf-ext-shared-tree-cache-circuit-breaker-and-pure-mode ()
  (etaf-ext-test--with-env _db
    (let* ((buf (generate-new-buffer " *etaf-ext-iso-test*"))
           (rt nil)
           (should-fail t))
      (unwind-protect
          (progn
            (etaf-ext-define test-healthy
              :name "Healthy Ext"
              :activation 'on-match
              :matches '(:apps (iso-app))
              :permissions '(read-tree companion)
              :on-attach (lambda (ctx)
                           (let ((hid (etaf-ext-test--find-text-host
                                       (etaf-ext-tree ctx) "Primary content")))
                             (when hid
                               (etaf-ext-companion
                                ctx
                                (list (cons hid (list :mode 'companion-after
                                                      :view (etaf-node 'text nil '("[HEALTHY-NOTE]"))))))))))
            (etaf-ext-define test-flaky
              :name "Flaky Ext"
              :activation 'on-command
              :matches '(:apps (iso-app))
              :permissions '(read-tree companion keys)
              :prefix-hint "z"
              :commands (list (list 'boom :subkey "b" :label "Boom"
                                    :fn (lambda (ctx)
                                          (let ((hid (etaf-ext-test--find-text-host
                                                      (etaf-ext-tree ctx) "Primary content")))
                                            (when hid
                                              (etaf-ext-companion
                                               ctx
                                               (list (cons hid (list :mode 'companion-after
                                                                     :view (etaf-node 'text nil '("[FLAKY-NOTE]"))))))))
                                          (when should-fail
                                            (error "Simulated plugin crash"))))))
            (setq rt (etaf-ext-test--mount
                      buf
                      (etaf-node 'column '(:width (ch 60))
                                 (list (etaf-node 'text nil '("Primary content paragraph."))))
                      '(:viewport-width 480 :viewport-height 20
                                        :meta (:app iso-app :kind document))))
            (let* ((c1 (etaf-ext-attach 'test-healthy rt))
                   (c2 (etaf-ext-attach 'test-flaky rt))
                   (t1 (etaf-ext-tree c1))
                   (t2 (etaf-ext-tree c2)))
              (should (eq t1 t2)))
            (should (string-search "[HEALTHY-NOTE]" (etaf-ext-test--buf-text rt)))
            (dotimes (_ 3)
              (etaf-ext-run-command 'test-flaky 'boom rt))
            (should (etaf-ext-suspended-p 'test-flaky))
            (should (= (length (etaf-ext-errors 'test-flaky)) 3))
            (let ((txt (etaf-ext-test--buf-text rt)))
              (should-not (string-search "[FLAKY-NOTE]" txt))
              (should (string-search "[HEALTHY-NOTE]" txt)))
            (setq should-fail nil)
            (etaf-ext-reset 'test-flaky)
            (should-not (etaf-ext-suspended-p 'test-flaky))
            (should (null (etaf-ext-errors 'test-flaky)))
            (should (etaf-ext-pure-mode-toggle rt))
            (should (etaf-ext-pure-mode-p rt))
            (should-not (string-search "[HEALTHY-NOTE]" (etaf-ext-test--buf-text rt)))
            (should-not (etaf-ext-pure-mode-toggle rt))
            (should-not (etaf-ext-pure-mode-p rt))
            (should (string-search "[HEALTHY-NOTE]" (etaf-ext-test--buf-text rt))))
        (etaf-ext-unregister 'test-healthy)
        (etaf-ext-unregister 'test-flaky)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; 5. Multi-extension coexistence (decorate + companions + overlays + theme)

(ert-deftest etaf-ext-multi-owner-decorate-companion-overlay-and-theme ()
  (etaf-ext-test--with-env _db
    (let* ((buf (generate-new-buffer " *etaf-ext-coex-core*"))
           (rt nil)
           (theme (etaf-ext-theme)))
      (should (stringp (plist-get theme :ext-bg)))
      (should (stringp (plist-get theme :ext-fg)))
      (should (stringp (plist-get theme :ui-accent)))
      (unwind-protect
          (progn
            (etaf-ext-define test-dec-ext
              :name "Span Decorator"
              :activation 'on-match
              :matches '(:apps (coex-app))
              :priority 40
              :permissions '(read-tree decorate companion)
              :on-attach (lambda (ctx)
                           (let ((hid (etaf-ext-test--find-text-host
                                       (etaf-ext-tree ctx) "Shared paragraph")))
                             (when hid
                               (etaf-ext-decorate
                                ctx (list (cons hid '(:spans (((0 . 6) . (:weight bold)))))))
                               (etaf-ext-companion
                                ctx (list (cons hid (list :mode 'companion-after
                                                          :view (etaf-node 'text nil '("[COMP-A]"))))))))))
            (etaf-ext-define test-ov-ext
              :name "Overlay Badge"
              :activation 'on-match
              :matches '(:apps (coex-app))
              :priority 60
              :permissions '(read-tree companion overlay)
              :on-attach (lambda (ctx)
                           (let ((hid (etaf-ext-test--find-text-host
                                       (etaf-ext-tree ctx) "Shared paragraph")))
                             (when hid
                               (etaf-ext-companion
                                ctx (list (cons hid (list :mode 'companion-after
                                                          :view (etaf-node 'text nil '("[COMP-B]")))))))
                             (etaf-ext-set-overlay
                              ctx (etaf-node 'box '(:layer root :position absolute :left (px 0) :top (lh 4))
                                             (list (etaf-node 'text nil '("[OV-BADGE]"))))))))
            (setq rt (etaf-ext-test--mount
                      buf
                      (etaf-node 'column '(:width (ch 64))
                                 (list (etaf-node 'text nil '("Shared paragraph for multi-owner check."))))
                      '(:viewport-width 520 :viewport-height 16
                                        :meta (:app coex-app :kind document))))
            (let ((txt (etaf-ext-test--buf-text rt)))
              (should (string-search "Shared paragraph" txt))
              (should (string-search "[COMP-A]" txt))
              (should (string-search "[COMP-B]" txt))
              (should (string-search "[OV-BADGE]" txt))
              ;; Priority ordering: COMP-A (P40) before COMP-B (P60)
              (should (< (string-search "[COMP-A]" txt)
                         (string-search "[COMP-B]" txt))))
            ;; Disabling one leaves the other completely intact
            (etaf-ext-disable 'test-ov-ext)
            (let ((txt (etaf-ext-test--buf-text rt)))
              (should (string-search "[COMP-A]" txt))
              (should-not (string-search "[COMP-B]" txt))
              (should-not (string-search "[OV-BADGE]" txt)))
            ;; Conditional activation + atomic mixed etaf-ext-present
            (let ((allow-cond nil)
                  (cond-trigger nil))
              (unwind-protect
                  (progn
                    (etaf-ext-define test-cond-ext
                      :name "Conditional Ext"
                      :activation (lambda (_rt) allow-cond)
                      :matches '(:apps (coex-app))
                      :permissions '(read-tree companion override)
                      :on-attach (lambda (ctx)
                                   (setq cond-trigger (etaf-ext-ctx-trigger ctx))
                                   (let ((hid (etaf-ext-test--find-text-host
                                               (etaf-ext-tree ctx) "Shared paragraph")))
                                     (when hid
                                       (etaf-ext-present
                                        ctx (list (cons hid (list :mode 'companion-after
                                                                  :view (etaf-node 'text nil '("[COND-MIX]"))))))))))
                    (should (eq (plist-get (etaf-ext-info 'test-cond-ext) :activation) 'on-condition))
                    (should-not (etaf-ext-context 'test-cond-ext rt))
                    (setq allow-cond t)
                    (etaf-ext-sync rt)
                    (should (etaf-ext-context 'test-cond-ext rt))
                    (should (eq cond-trigger 'auto))
                    (should (string-search "[COND-MIX]" (etaf-ext-test--buf-text rt))))
                (etaf-ext-unregister 'test-cond-ext))))
        (etaf-ext-unregister 'test-dec-ext)
        (etaf-ext-unregister 'test-ov-ext)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;;; 6. Extension Manager UI & key-help exposure

(ert-deftest etaf-ext-manager-ui-opens-filters-toggles-and-closes-cleanly ()
  (etaf-ext-test--with-env _db
    (let* ((doc-buf (generate-new-buffer " *etaf-ext-mgr-target*"))
           (doc-rt nil)
           (mgr-buf nil))
      (unwind-protect
          (progn
            (should-error (etaf-ext-register 'bad-icon :icon 123) :type 'etaf-ext-error)
            (should-error (etaf-ext-register 'bad-tone :tone 'bogus) :type 'etaf-ext-error)
            (etaf-ext-define test-mgr-ext
              :name "演示扩展"
              :version "1.2.0"
              :icon "徽"
              :tone 'warning
              :prefix-hint "m"
              :description "用于验证管理界面渲染与快捷键层暴露。"
              :activation 'on-command
              :matches '(:apps t)
              :permissions '(read-tree keys)
              :commands (list (list 'ping :subkey "p" :suggested-key "C-c C-y"
                                    :label "触发演示命令"
                                    :fn (lambda (_ctx) 'pong))))
            (let ((info (etaf-ext-info 'test-mgr-ext)))
              (should (equal (plist-get info :icon) "徽"))
              (should (eq (plist-get info :tone) 'warning))
              (should (equal (plist-get info :prefix-hint) "m")))
            (setq doc-rt (etaf-ext-test--mount
                          doc-buf
                          (etaf-node 'column '(:width (ch 60))
                                     (list (etaf-node 'text nil '("Target document body."))))
                          '(:viewport-width 480 :viewport-height 20
                                            :meta (:app demo-web :kind document
                                                        :title "Demo Target Page"))))
            (let* ((hdata (etaf-help-data doc-rt))
                   (groups (plist-get hdata :groups))
                   (ext-group (cl-find 'extension groups :key (lambda (g) (plist-get g :kind)))))
              (should ext-group)
              (should (cl-some (lambda (item) (equal (plist-get item :key) "C-c C-e"))
                               (plist-get ext-group :entries)))
              (should (cl-some (lambda (item) (equal (plist-get item :key) "C-c C-y"))
                               (plist-get ext-group :entries))))
            (setq mgr-buf (etaf-ext-manage doc-rt))
            (should (buffer-live-p mgr-buf))
            (let* ((mgr-rt (etaf-runtime-for-buffer mgr-buf))
                   (txt (etaf-ext-test--buf-text mgr-rt)))
              (should mgr-rt)
              (should (string-search "ETAF 扩展中心" txt))
              (should (string-search "Demo Target Page" txt))
              (should (string-search "演示扩展" txt))
              (should (string-search "徽" txt))
              (should (buffer-local-value 'mode-line-format mgr-buf))
              (etaf-ext-disable 'test-mgr-ext)
              (should-not (etaf-ext-enabled-p 'test-mgr-ext))
              (etaf-ext-enable 'test-mgr-ext)
              (should (etaf-ext-enabled-p 'test-mgr-ext)))
            (etaf-app-close mgr-buf)
            (should-not (buffer-live-p mgr-buf))
            ;; Non-graphic popup entry degrades cleanly to full-buffer manager.
            (let ((pop-buf (etaf-ext-manage-popup doc-rt)))
              (should (buffer-live-p pop-buf))
              (etaf-app-close pop-buf)
              (should-not (buffer-live-p pop-buf))))
        (etaf-ext-unregister 'test-mgr-ext)
        (when (and mgr-buf (buffer-live-p mgr-buf))
          (ignore-errors (etaf-app-close mgr-buf)))
        (when (and doc-rt (etaf-runtime-mounted-p doc-rt)) (etaf-unmount doc-rt))
        (when (buffer-live-p doc-buf) (kill-buffer doc-buf))))))

;;;; 7. Key conflict firewall, persisted user overrides and unified dispatch

(ert-deftest etaf-ext-key-conflict-firewall-overrides-and-unified-dispatch ()
  (etaf-ext-test--with-env _db
    (let* ((buf (generate-new-buffer " *etaf-ext-key-test*"))
           (rt nil)
           (hits nil)
           (saved-ce (lookup-key global-map (kbd "C-c e")))
           (saved-mf (lookup-key global-map (kbd "M-f")))
           (etaf-ext-key-prefix "C-c C-e")
           (etaf-ext-keybinding-policy 'safe)
           (fake-prefix (let ((m (make-sparse-keymap)))
                          (define-key m (kbd "e") #'ignore)
                          m)))
      (unwind-protect
          (progn
            ;; Legacy hardcoded :key keyword is rejected cleanly.
            (should-error
             (etaf-ext-register 'test-legacy-key
                                :commands (list (list 'old :key "C-c z" :fn #'ignore)))
             :type 'etaf-ext-error)
            ;; Simulate user global prefix `C-c e' (like `etaf-posframe-app-prefix').
            (define-key global-map (kbd "C-c e") fake-prefix)
            (etaf-ext-define test-key-a
              :name "Key Ext A"
              :activation 'on-command
              :priority 20
              :prefix-hint "x"
              :permissions '(keys)
              :commands
              (list (list 'conflict-pfx
                          :subkey "p"
                          :suggested-key "C-c e p"
                          :label "Should Skip Global Prefix"
                          :fn (lambda (_ctx) (push 'conflict-pfx hits)))
                    (list 'printing-skip
                          :subkey "j"
                          :suggested-key "j"
                          :label "Should Skip Printing Char"
                          :fn (lambda (_ctx) (push 'printing-skip hits)))
                    (list 'hints-like
                          :subkey "f"
                          :suggested-key "M-f"
                          :label "Safe M-f"
                          :fn (lambda (_ctx) (push 'hints-like hits)))))
            (etaf-ext-define test-key-b
              :name "Key Ext B"
              :activation 'on-command
              :priority 60
              :prefix-hint "x"
              :permissions '(keys)
              :commands
              (list (list 'dup-sugg
                          :subkey "b"
                          :suggested-key "M-f"
                          :label "Lower Priority M-f"
                          :fn (lambda (_ctx) (push 'dup-sugg hits)))))
            (setq rt (etaf-ext-test--mount
                      buf
                      (etaf-node 'column '(:width (ch 50))
                                 (list (etaf-node 'text nil '("Key firewall test."))))
                      '(:viewport-width 400 :viewport-height 14
                                        :meta (:app key-app :kind document))))
            ;; Verify global-prefix collision, printing-char guard, and sibling priority.
            (let* ((bs-a (etaf-ext-command-bindings rt 'test-key-a))
                   (bs-b (etaf-ext-command-bindings rt 'test-key-b))
                   (r-pfx (cl-find 'conflict-pfx bs-a :key (lambda (r) (plist-get r :cmd-id))))
                   (r-prt (cl-find 'printing-skip bs-a :key (lambda (r) (plist-get r :cmd-id))))
                   (r-mf  (cl-find 'hints-like bs-a :key (lambda (r) (plist-get r :cmd-id))))
                   (r-dup (cl-find 'dup-sugg bs-b :key (lambda (r) (plist-get r :cmd-id)))))
              (should (eq (plist-get r-pfx :status) 'conflict))
              (should (eq (plist-get (plist-get r-pfx :conflict) :kind) 'global-prefix))
              (should-not (plist-get r-pfx :effective-key))
              (should (equal (plist-get r-pfx :dispatch-key) "C-c C-e x p"))
              (should (eq (plist-get r-prt :status) 'conflict))
              (should (eq (plist-get (plist-get r-prt :conflict) :kind) 'printing-key))
              (should (eq (plist-get r-mf :status) 'active))
              (should (equal (plist-get r-mf :effective-key) "M-f"))
              ;; Higher-priority ext A wins M-f; lower-priority ext B is skipped cleanly.
              (should (eq (plist-get r-dup :status) 'conflict))
              (should (eq (plist-get (plist-get r-dup :conflict) :kind) 'extension))
              ;; Both extensions asked for :prefix-hint "x"; B gets a distinct fallback letter.
              (should (equal (plist-get r-pfx :prefix-key) "x"))
              (should-not (equal (plist-get r-dup :prefix-key) "x")))
            ;; User custom M-f in global-map blocks suggested M-f too.
            (define-key global-map (kbd "M-f") #'forward-sexp)
            (let* ((conflict (etaf-ext-check-key-conflict "M-f" rt 'test-key-a 'hints-like)))
              (should conflict)
              (should (eq (plist-get conflict :kind) 'global-key)))
            (define-key global-map (kbd "M-f") saved-mf)
            ;; Unified two-step prefix dispatch executes without any hardcoded C-c <letter>.
            (save-window-excursion
              (set-window-buffer (selected-window) buf)
              (with-current-buffer buf
                (execute-kbd-macro (kbd "C-c C-e x p"))))
            (should (equal hits '(conflict-pfx)))
            ;; Persisted user overrides: reserved key rejected, :unbound suppresses M-f,
            ;; explicit user key takes precedence over higher-priority suggested key.
            (should-error (etaf-ext-set-key 'test-key-a 'hints-like "?") :type 'etaf-ext-error)
            (etaf-ext-set-key 'test-key-a 'hints-like :unbound)
            (should (eq (etaf-ext-key-override 'test-key-a 'hints-like) :unbound))
            (let* ((r-mf (cl-find 'hints-like (etaf-ext-command-bindings rt 'test-key-a)
                                  :key (lambda (r) (plist-get r :cmd-id))))
                   (r-dup (cl-find 'dup-sugg (etaf-ext-command-bindings rt 'test-key-b)
                                   :key (lambda (r) (plist-get r :cmd-id)))))
              (should (eq (plist-get r-mf :status) 'unbound))
              (should-not (plist-get r-mf :effective-key))
              ;; Once A releases M-f, B's suggested M-f automatically activates.
              (should (eq (plist-get r-dup :status) 'active))
              (should (equal (plist-get r-dup :effective-key) "M-f")))
            (etaf-ext-set-key 'test-key-a 'conflict-pfx "C-c C-u")
            (should (equal (etaf-ext-key-override 'test-key-a 'conflict-pfx) "C-c C-u"))
            (save-window-excursion
              (set-window-buffer (selected-window) buf)
              (with-current-buffer buf
                (execute-kbd-macro (kbd "C-c C-u"))))
            (should (equal hits '(conflict-pfx conflict-pfx)))
            (etaf-ext-reset-key 'test-key-a 'conflict-pfx)
            (etaf-ext-reset-key 'test-key-a 'hints-like)
            (should-not (etaf-ext-key-override 'test-key-a 'conflict-pfx))
            ;; Policy `prefix-only' suppresses suggested M-f while keeping `C-c C-e'.
            (let ((etaf-ext-keybinding-policy 'prefix-only))
              (etaf-ext-sync rt)
              (let* ((r-mf (cl-find 'hints-like (etaf-ext-command-bindings rt 'test-key-a)
                                    :key (lambda (r) (plist-get r :cmd-id)))))
                (should (eq (plist-get r-mf :status) 'policy-skipped))
                (should-not (plist-get r-mf :effective-key))
                (should (equal (plist-get r-mf :dispatch-key) "C-c C-e x f")))))
        (define-key global-map (kbd "C-c e") saved-ce)
        (define-key global-map (kbd "M-f") saved-mf)
        (etaf-ext-unregister 'test-key-a)
        (etaf-ext-unregister 'test-key-b)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest etaf-ext-activity-and-notify-bridge ()
  "Extensions publish runtime-scoped live activities and protocol notifications."
  (etaf-ext-test--with-env _db
    (let* ((buf (generate-new-buffer " *etaf-ext-act-test*"))
           (rt nil)
           (seen nil)
           (etaf-notify-functions
            (list (lambda (entry) (push entry seen)))))
      (etaf-notify-clear)
      (unwind-protect
          (progn
            (etaf-ext-register
             'test-act-ext
             :name "Activity Test Ext"
             :permissions '(read-tree notify)
             :matches '(:apps (test-act-app))
             :activation 'on-match
             :on-attach
             (lambda (ctx)
               (etaf-ext-set-activity
                ctx (list :kind 'task
                          :state 'active
                          :priority 70
                          :title "扩展任务运行中"
                          :compact "任务 1/2"
                          :progress '(:value 1 :max 2 :unit items)))
               (etaf-ext-notify ctx "扩展提示" :detail "通过通用协议推送" :variant 'success)))
            (setq rt (etaf-ext-test--mount
                      buf (etaf-view (text :id 'body "Hello"))
                      (list :meta '(:app test-act-app))))
            (etaf-ext-sync rt)
            ;; Activity is published and notification flowed into `etaf-notify'.
            (let ((acts (etaf-activity-list 'task)))
              (should (= (length acts) 1))
              (should (eq (plist-get (car acts) :app) 'test-act-ext))
              (should (equal (plist-get (car acts) :title) "扩展任务运行中")))
            (should (= (length seen) 1))
            (should (equal (plist-get (car seen) :title) "扩展提示"))
            ;; Detaching automatically cleans up the owned live activity.
            (etaf-ext-detach 'test-act-ext rt)
            (should (null (etaf-activity-list 'task))))
        (etaf-ext-unregister 'test-act-ext)
        (etaf-notify-clear)
        (when (and rt (etaf-runtime-mounted-p rt)) (etaf-unmount rt))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(provide 'etaf-ext-tests)
;;; etaf-ext-tests.el ends here
