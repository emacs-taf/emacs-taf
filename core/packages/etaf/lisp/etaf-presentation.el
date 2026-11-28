;;; etaf-presentation.el --- Host presentations, tree inspection and overlays -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Retained Host presentation and tree inspection, Runtime metadata, named
;; root overlays and multi-owner Host presentation buckets.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-reactive)
(require 'etaf-view)
(require 'etaf-component)
(require 'etaf-txn)
(require 'etaf-host-bridge)
(require 'etaf-reconcile)

(declare-function etaf--root-init "etaf-runtime" (seg))
(declare-function etaf-runtime-require-mounted "etaf-runtime" (&optional runtime))

;;;; Host presentation and tree inspection

(defun etaf--runtime-index-host-ids (runtime)
  "Refresh and return RUNTIME's host-id -> segment table."
  (let ((table (or (etaf-runtime-host-ids runtime)
                   (setf (etaf-runtime-host-ids runtime)
                         (make-hash-table :test #'eql)))))
    (clrhash table)
    (cl-labels ((walk (seg)
                  (when seg
                    (when (and (eq (etaf--seg-kind seg) 'host)
                               (etaf--seg-live seg))
                      (puthash (etaf--host-id (etaf--seg-data seg)) seg table))
                    (dolist (kid (etaf--seg-kids seg))
                      (walk kid)))))
      (walk (etaf-runtime-root runtime)))
    table))

(defun etaf--runtime-seg-by-id (runtime host-id)
  "Return the live Host segment for integer HOST-ID in RUNTIME, or nil."
  (when (integerp host-id)
    (let* ((table (etaf-runtime-host-ids runtime))
           (seg (and table (gethash host-id table))))
      (unless (and seg (etaf--seg-live seg))
        (setq table (etaf--runtime-index-host-ids runtime)
              seg (gethash host-id table)))
      (and seg (etaf--seg-live seg) seg))))

(defun etaf--sanitize-host-props (props)
  "Return a data-only snapshot of Host PROPS without closures or cycles."
  (let ((tail props)
        (result nil)
        (has-press (and (functionp (plist-get props :on-press))
                        (not (plist-get props :disabled)))))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (or (memq key '(:keys :use :hover-content))
                    (etaf--event-property-p key)
                    (functionp value))
          (push key result)
          (push value result))))
    (when has-press
      (push :has-on-press result)
      (push t result))
    (nreverse result)))

(defun etaf--host-tree-collect (seg host-ids)
  "Collect read-only Host tree plists under SEG and index them in HOST-IDS."
  (when (and seg (etaf--seg-live seg))
    (if (eq (etaf--seg-kind seg) 'host)
        (let* ((host (etaf--seg-data seg))
               (id (etaf--host-id host))
               (item (etaf--seg-src seg))
               (tag (etaf--view-node-name item))
               (node (etaf--seg-node seg))
               (outer (etaf--seg-outer-node seg))
               (geo (or (and node (ebox-node-geometry node))
                        (and outer (not (eq outer node))
                             (ebox-node-geometry outer))))
               (children nil))
          (puthash id seg host-ids)
          (dolist (kid (etaf--seg-kids seg))
            (setq children (nconc children (etaf--host-tree-collect kid host-ids))))
          (list
           (list :id id
                 :ref (etaf--host-ref host)
                 :tag tag
                 :text (when (eq tag 'text) (etaf--host-text host))
                 :props (etaf--sanitize-host-props (etaf--host-props host))
                 :geometry geo
                 :children children)))
      (let ((result nil))
        (dolist (kid (etaf--seg-kids seg) result)
          (setq result (nconc result (etaf--host-tree-collect kid host-ids))))))))

;;;###autoload
(defun etaf-runtime-host-tree (&optional runtime)
  "Return mounted RUNTIME's committed application Host tree as read-only data.
RUNTIME defaults to the active or current-buffer Runtime.  Transient surfaces
and attached presentation companions are excluded; `:text' holds the
application's authoritative text even when a presentation overrides it."
  (let* ((runtime (etaf-runtime-require-mounted runtime))
         (table (or (etaf-runtime-host-ids runtime)
                    (setf (etaf-runtime-host-ids runtime)
                          (make-hash-table :test #'eql)))))
    (clrhash table)
    (etaf--host-tree-collect (etaf-runtime-root runtime) table)))

(defun etaf--runtime-window-line-band (runtime)
  "Return (TOP . BOTTOM) 0-based visible buffer lines for RUNTIME, or nil."
  (let* ((buf (etaf-runtime-buffer runtime))
         (win (and (buffer-live-p buf) (get-buffer-window buf t))))
    (when (window-live-p win)
      (with-current-buffer buf
        (let* ((top (1- (line-number-at-pos (window-start win) t)))
               (end-pos (window-end win t))
               (bot (if end-pos
                        (line-number-at-pos end-pos t)
                      (+ top (window-body-height win)))))
          (cons (max 0 top) (max (1+ top) bot)))))))

(defun etaf--seg-clip-band (seg window-band)
  "Return (CLIP-TOP . CLIP-BOTTOM) for Host SEG intersected with WINDOW-BAND."
  (let ((top (and window-band (car window-band)))
        (bot (and window-band (cdr window-band)))
        (cur (etaf--seg-parent seg)))
    (while cur
      (when (eq (etaf--seg-kind cur) 'host)
        (let* ((host (etaf--seg-data cur))
               (ov (and host
                        (or (plist-get (etaf--host-eprops host) :overflow)
                            (plist-get (etaf--host-props host) :overflow)))))
          (when (memq ov '(scroll auto hidden))
            (when-let* ((node (etaf--seg-node cur))
                        (geo (ebox-node-geometry node)))
              (let ((ct (plist-get geo :y))
                    (cb (+ (plist-get geo :y) (max 0 (plist-get geo :height)))))
                (setq top (if top (max top ct) ct)
                      bot (if bot (min bot cb) cb)))))))
      (setq cur (etaf--seg-parent cur)))
    (when (and top bot)
      (cons top bot))))

;;;###autoload
(defun etaf-runtime-host-geometries (runtime host-ids)
  "Return live geometry and visibility for integer HOST-IDS in RUNTIME.
Return an alist of `(HOST-ID . PLIST)' for each live laid-out Host, where
PLIST holds `:x', `:y', `:width', `:height', `:clip-top', `:clip-bottom' and
`:visible-p'.  `:y' reflects every enclosing `:overflow scroll' offset."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (proper-list-p host-ids)
    (signal 'etaf-runtime-error (list "HOST-IDS must be a list" host-ids)))
  (let ((win-band (etaf--runtime-window-line-band runtime))
        (out nil))
    (dolist (id host-ids (nreverse out))
      (when-let* ((seg (etaf--runtime-seg-by-id runtime id)))
        (let* ((node (etaf--seg-node seg))
               (outer (etaf--seg-outer-node seg))
               (geo (or (and node (ebox-node-geometry node))
                        (and outer (not (eq outer node))
                             (ebox-node-geometry outer)))))
          (when geo
            (let* ((y (plist-get geo :y))
                   (h (max 1 (or (plist-get geo :height) 1)))
                   (clip (etaf--seg-clip-band seg win-band))
                   (ct (and clip (car clip)))
                   (cb (and clip (cdr clip)))
                   (vis (if clip
                            (and (> (+ y h) ct) (< y cb))
                          t)))
              (push (cons id (list :x (plist-get geo :x)
                                   :y y
                                   :width (plist-get geo :width)
                                   :height (plist-get geo :height)
                                   :clip-top ct
                                   :clip-bottom cb
                                   :visible-p vis))
                    out))))))))

;;;###autoload
(defun etaf-runtime-trigger-host-press (runtime host-id)
  "Dispatch an enabled `press' event on committed HOST-ID in RUNTIME.
Return non-nil when dispatched, or nil when HOST-ID is absent or has no
enabled `:on-press' handler."
  (etaf--assert-not-rendering 'trigger-host-press)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id)))
    (let* ((host (etaf--seg-data seg))
           (props (etaf--host-props host)))
      (when (and (not (plist-get props :disabled))
                 (functionp (plist-get props :on-press)))
        (etaf-dispatch-event runtime (etaf--host-ref host) 'press)
        t))))

;;;###autoload
(defun etaf-runtime-focus-host (runtime host-id)
  "Move logical focus to committed integer HOST-ID in mounted RUNTIME.
Return non-nil when HOST-ID was focused, or nil when absent or ineligible."
  (etaf--assert-not-rendering 'focus-host)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id))
              (node (etaf--seg-node seg)))
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (condition-case nil
            (progn (ebox-focus node buf) t)
          (user-error nil))))))

;;;###autoload
(defun etaf-runtime-scroll-host-into-view (runtime host-id &optional align)
  "Scroll enclosing scrollers of mounted RUNTIME so HOST-ID is visible.
ALIGN is nil (least movement), `start' or `end'.  Return non-nil when HOST-ID
was live, or nil when absent."
  (etaf--assert-not-rendering 'scroll-host-into-view)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (integerp host-id)
    (signal 'etaf-runtime-error (list "Host ID must be an integer" host-id)))
  (unless (memq align '(nil start end))
    (signal 'etaf-runtime-error (list "Invalid scroll alignment" align)))
  (when-let* ((seg (etaf--runtime-seg-by-id runtime host-id))
              (node (etaf--seg-node seg)))
    (let ((buf (etaf-runtime-buffer runtime)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (ebox-node-scroll-into-view node align)
          ;; When displayed in an Emacs window, also reveal the root line.
          (when-let* ((win (get-buffer-window buf t))
                      (rline (ebox-node-root-line node)))
            (let* ((band (etaf--runtime-window-line-band runtime))
                   (top (and band (car band)))
                   (bot (and band (cdr band))))
              (when (and top bot (or (< rline top) (>= rline bot)))
                (save-excursion
                  (goto-char (point-min))
                  (forward-line rline)
                  (set-window-point win (point))
                  (with-selected-window win
                    (recenter (pcase align
                                ('start 0)
                                ('end -1)
                                (_ nil)))))))))
        t))))

(defun etaf--text-host-offset-for-pos (buf node text bounds target-pos)
  "Return character offset in TEXT corresponding to TARGET-POS inside BOUNDS."
  (with-current-buffer buf
    (let* ((start (car bounds))
           (limit (min target-pos (cdr bounds)))
           (len (length text))
           (idx 0)
           (p start))
      (while (and (< p limit) (< idx len))
        (when (and (eq (get-text-property p 'ebox-node) node)
                   (not (eql (char-after p) ?\u200b))
                   (not (eq (car-safe (get-text-property p 'display)) 'space)))
          (let ((ch (char-after p))
                (src (aref text idx)))
            (cond
             ((eql ch src) (setq idx (1+ idx)))
             ((and (eql ch ?\n) (memq src '(?\s ?\t ?\n)))
              (setq idx (1+ idx))))))
        (setq p (1+ p)))
      idx)))

;;;###autoload
(defun etaf-runtime-host-text-offset-at (runtime &optional position)
  "Return text Host offset and optional active region at POSITION in RUNTIME.
POSITION defaults to `point' in RUNTIME's buffer.  When POSITION sits inside a
mounted text Host, return a plist `(:id HOST-ID :offset CHAR-OFFSET :text TEXT
:region REGION)' where `:region' is `(BEG . END)' in `:text' when Emacs's
region is active and overlaps that Host, else nil.  Return nil when POSITION is
not on a text Host."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((buf (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let* ((pos (or position (point)))
               (node (and (>= pos (point-min)) (<= pos (point-max))
                          (ebox-node-at pos buf)))
               (nodes (etaf-runtime-nodes runtime))
               (seg (and node (gethash node nodes))))
          (when (and seg (eq (etaf--seg-kind seg) 'host) (etaf--seg-live seg)
                     (eq (etaf--view-node-name (etaf--seg-src seg)) 'text))
            (let* ((host (etaf--seg-data seg))
                   (text (or (etaf--host-text host) ""))
                   (bounds (ebox-node-bounds node t)))
              (when bounds
                (let* ((offset (etaf--text-host-offset-for-pos
                                buf node text bounds pos))
                       (region
                        (when (and (use-region-p)
                                   (< (region-beginning) (cdr bounds))
                                   (> (region-end) (car bounds)))
                          (let ((rbeg (etaf--text-host-offset-for-pos
                                       buf node text bounds
                                       (max (car bounds) (region-beginning))))
                                (rend (etaf--text-host-offset-for-pos
                                       buf node text bounds
                                       (min (cdr bounds) (region-end)))))
                            (when (< rbeg rend)
                              (cons rbeg rend))))))
                  (list :id (etaf--host-id host)
                        :offset offset
                        :text (substring-no-properties text)
                        :region region))))))))))

;;;; Runtime metadata

(defun etaf--meta-copy (value)
  "Return a detached copy of metadata VALUE."
  (cond
   ((stringp value) (substring-no-properties value))
   ((or (null value) (eq value t) (numberp value) (symbolp value)) value)
   ((proper-list-p value) (mapcar #'etaf--meta-copy value))
   ((consp value) (cons (etaf--meta-copy (car value))
                        (etaf--meta-copy (cdr value))))
   (t value)))

(defun etaf--meta-resolve (spec)
  "Resolve metadata SPEC plist, reading any reactive values."
  (when spec
    (let (out)
      (cl-loop for (k v) on spec by #'cddr
               do (let ((val (cond
                              ((or (etaf-ref-p v) (etaf-computed-p v))
                               (etaf-value v))
                              ((functionp v) (funcall v))
                              (t v))))
                    (setq out (plist-put out k (etaf--meta-copy val)))))
      out)))

(defun etaf--meta-has-dynamic-p (spec)
  "Return non-nil when metadata SPEC contains reactive or callable values."
  (cl-loop for (_k v) on spec by #'cddr
           thereis (or (etaf-ref-p v) (etaf-computed-p v) (functionp v))))

(defun etaf--runtime-install-meta (runtime meta silent)
  "Install META plist on mounted RUNTIME.
When SILENT is nil and the resolved snapshot changed, run
`etaf-runtime-meta-change-functions'."
  (when-let* ((old-scope (etaf-runtime-meta-scope runtime)))
    (setf (etaf-runtime-meta-scope runtime) nil)
    (etaf-scope-stop old-scope))
  (setf (etaf-runtime-meta-spec runtime) (copy-sequence meta))
  (let* ((prev (etaf-runtime-meta-snapshot runtime))
         (initial nil))
    (if (etaf--meta-has-dynamic-p meta)
        (let ((scope (etaf-effect-scope :detached t :name 'etaf-runtime-meta))
              (first-run t))
          (setf (etaf-runtime-meta-scope runtime) scope)
          (etaf-scope-run
           scope
           (lambda ()
             (etaf-watch-effect
              (lambda ()
                (let ((resolved (etaf--meta-resolve meta)))
                  (if first-run
                      (progn
                        (setq first-run nil initial resolved)
                        (setf (etaf-runtime-meta-snapshot runtime) resolved))
                    (unless (equal resolved (etaf-runtime-meta-snapshot runtime))
                      (setf (etaf-runtime-meta-snapshot runtime) resolved)
                      (when (etaf-runtime-mounted-p runtime)
                        (etaf--run-runtime-hooks
                         'etaf-runtime-meta-change-functions
                         runtime (etaf--meta-copy resolved)))))))
              :name 'etaf-runtime-meta))))
      (setq initial (etaf--meta-resolve meta))
      (setf (etaf-runtime-meta-snapshot runtime) initial))
    (when (and (not silent) (not (equal initial prev)))
      (etaf--run-runtime-hooks
       'etaf-runtime-meta-change-functions
       runtime (etaf--meta-copy initial)))
    (etaf--meta-copy initial)))

;;;###autoload
(defun etaf-runtime-meta (&optional runtime)
  "Return a detached copy of mounted RUNTIME's metadata plist, or nil.
RUNTIME defaults to the active or current-buffer Runtime."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (etaf--meta-copy (etaf-runtime-meta-snapshot runtime)))

;;;###autoload
(defun etaf-runtime-set-meta (runtime meta)
  "Set mounted RUNTIME's metadata plist to META and return the resolved plist.
META is nil or a proper plist whose values may be static data, `etaf-ref',
`etaf-computed' or zero-argument functions.  Reactive changes notify
`etaf-runtime-meta-change-functions'."
  (etaf--assert-not-rendering 'set-meta)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (or (null meta)
              (and (proper-list-p meta) (zerop (% (length meta) 2))))
    (signal 'etaf-runtime-error (list "Runtime meta must be a plist or nil" meta)))
  (etaf--runtime-install-meta runtime meta nil))

;;;; Named root overlays

;;;###autoload
(defun etaf-runtime-set-overlay (runtime key view &optional origin)
  "Mount, update or clear named root-layer overlay KEY with VIEW in RUNTIME.
KEY is a non-nil symbol identifying the overlay owner.  When VIEW is nil,
remove KEY's overlay.  VIEW inherits ORIGIN's (or the root's) Context and
Theme without remounting application Components or firing
`etaf-runtime-after-commit-functions'.  Return non-nil when changed."
  (etaf--assert-not-rendering 'set-overlay)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (symbolp key) key)
    (signal 'etaf-runtime-error (list "Overlay key must be a non-nil symbol" key)))
  (let ((etaf--in-presentation-mutation t)
        (changed nil))
    (etaf-call-with-batch
     (lambda ()
       (let ((existing (assq key (etaf-runtime-overlay-entries runtime))))
         (if (null view)
             (when existing
               (setf (etaf-runtime-overlay-entries runtime)
                     (assq-delete-all key (etaf-runtime-overlay-entries runtime)))
               (etaf--dispose (cdr existing) nil)
               (etaf--root-dirty runtime)
               (setq changed t))
           (if existing
               (let ((oseg (cdr existing)))
                 (setf (etaf--seg-src oseg) view)
                 (etaf--patch-kids oseg (etaf--flatten view) (etaf--seg-ctx oseg))
                 (etaf--root-dirty runtime)
                 (setq changed t))
             (let* ((source (or (and origin (etaf--runtime-host-seg runtime origin))
                                (etaf-runtime-root runtime)))
                    (ctx (etaf--ictx-make
                          :runtime runtime
                          :context (etaf--ictx-context (etaf--seg-ctx source))))
                    (oseg (etaf--seg-make
                           :kind 'overlay :src view :ctx ctx
                           :node (etaf-runtime-mounted-root runtime))))
               (condition-case err
                   (progn
                     (etaf--root-init oseg)
                     (setf (etaf--seg-live oseg) t
                           (etaf-runtime-overlay-entries runtime)
                           (append (etaf-runtime-overlay-entries runtime)
                                   (list (cons key oseg))))
                     (etaf--root-dirty runtime)
                     (setq changed t))
                 ((error quit)
                  (etaf--dispose oseg nil)
                  (signal (car err) (cdr err))))))))))
    changed))

;;;###autoload
(defun etaf-runtime-clear-overlay (runtime &optional key)
  "Remove named root overlays in mounted RUNTIME and return count removed.
When KEY is non-nil, remove only KEY; otherwise remove all overlays."
  (etaf--assert-not-rendering 'clear-overlay)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when (and key (not (symbolp key)))
    (signal 'etaf-runtime-error (list "Overlay key must be a symbol or nil" key)))
  (let ((etaf--in-presentation-mutation t)
        (removed 0))
    (if key
        (when (etaf-runtime-set-overlay runtime key nil)
          (setq removed 1))
      (let ((entries (etaf-runtime-overlay-entries runtime)))
        (when entries
          (etaf-call-with-batch
           (lambda ()
             (setf (etaf-runtime-overlay-entries runtime) nil)
             (dolist (entry entries)
               (etaf--dispose (cdr entry) nil)
               (cl-incf removed))
             (etaf--root-dirty runtime))))))
    removed))

;;;; Multi-owner Host presentations

(defun etaf--pb-empty-p (bucket)
  "Return non-nil when presentation BUCKET has no active entries."
  (and (null (etaf--pb-decorations bucket))
       (null (etaf--pb-companions bucket))
       (null (etaf--pb-overrides bucket))))

(defun etaf--pb-all-entries (bucket)
  "Return all active `etaf--pres' entries in BUCKET."
  (when bucket
    (append (etaf--pb-decorations bucket)
            (etaf--pb-companions bucket)
            (etaf--pb-overrides bucket))))

(defun etaf--pb-sort (entries &optional latest-first)
  "Return ENTRIES sorted by ascending priority and deterministic seq order."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((pa (etaf--pres-priority a))
                (pb (etaf--pres-priority b)))
            (if (/= pa pb)
                (< pa pb)
              (if latest-first
                  (> (etaf--pres-seq a) (etaf--pres-seq b))
                (< (etaf--pres-seq a) (etaf--pres-seq b))))))))

(defun etaf--pb-effective-text (host bucket)
  "Return rendered display string for text HOST under presentation BUCKET."
  (let* ((active-ov (and bucket (etaf--pb-active-override bucket)))
         (base (or (and active-ov (etaf--pres-text-override active-ov))
                   (etaf--host-text host)
                   ""))
         (decs (and bucket (etaf--pb-decorations bucket))))
    (if (null decs)
        base
      (let ((copy (copy-sequence base))
            (len (length base)))
        (dolist (dec decs copy)
          (when-let* ((wface (etaf--pres-face dec)))
            (when (> len 0)
              (add-face-text-property 0 len wface nil copy)))
          (dolist (span (etaf--pres-spans dec))
            (let* ((range (car span))
                   (raw (cdr span))
                   (face (if (and (consp raw) (keywordp (car raw))
                                  (plist-member raw :face))
                             (plist-get raw :face)
                           raw))
                   (beg (max 0 (min len (car range))))
                   (end (max beg (min len (cdr range)))))
              (when (and face (< beg end))
                (add-face-text-property beg end face nil copy)))))))))

(defun etaf--pres-validate-spans (spans)
  "Validate SPANS list for a `decorate' presentation spec."
  (unless (proper-list-p spans)
    (signal 'etaf-runtime-error (list "Decoration :spans must be a list" spans)))
  (dolist (span spans)
    (unless (and (consp span)
                 (consp (car span))
                 (integerp (caar span))
                 (integerp (cdar span))
                 (<= 0 (caar span))
                 (<= (caar span) (cdar span)))
      (signal 'etaf-runtime-error (list "Invalid decoration span" span)))
    (let* ((raw (cdr span))
           (face (if (and (consp raw) (keywordp (car raw))
                          (plist-member raw :face))
                     (plist-get raw :face)
                   raw)))
      (unless (or (symbolp face) (proper-list-p face))
        (signal 'etaf-runtime-error (list "Invalid decoration span face" span))))))

(defun etaf--pres-validate-spec (spec)
  "Validate presentation SPEC plist or nil, signaling `etaf-runtime-error'."
  (when spec
    (unless (proper-list-p spec)
      (signal 'etaf-runtime-error (list "Presentation spec must be a plist or nil" spec)))
    (cl-loop for (k _v) on spec by #'cddr
             unless (memq k '(:mode :text :view :spans :face :priority))
             do (signal 'etaf-runtime-error (list "Unknown presentation spec key" k)))
    (when (plist-member spec :priority)
      (let ((prio (plist-get spec :priority)))
        (unless (integerp prio)
          (signal 'etaf-runtime-error (list "Presentation :priority must be an integer" prio)))))
    (let ((mode (plist-get spec :mode))
          (text (plist-get spec :text))
          (view (plist-get spec :view))
          (spans (plist-get spec :spans))
          (face (plist-get spec :face)))
      (unless (memq mode '(decorate override companion-inside companion-after companion-beside))
        (signal 'etaf-runtime-error (list "Invalid presentation :mode" mode)))
      (pcase mode
        ('decorate
         (when (or text view)
           (signal 'etaf-runtime-error
                   (list "Decorate presentation does not take :text or :view" spec)))
         (when spans (etaf--pres-validate-spans spans))
         (unless (or (null face) (symbolp face) (proper-list-p face))
           (signal 'etaf-runtime-error (list "Invalid decoration :face" face))))
        ('override
         (when (or spans face)
           (signal 'etaf-runtime-error
                   (list "Override presentation does not take :spans or :face" spec)))
         (when (and text view)
           (signal 'etaf-runtime-error
                   (list "Override presentation takes either :text or :view, not both")))
         (unless (or (stringp text) view)
           (signal 'etaf-runtime-error
                   (list "Override presentation requires string :text or :view" spec))))
        (_
         (when (or text spans face)
           (signal 'etaf-runtime-error
                   (list "Companion presentation takes :view, not :text, :spans or :face" spec)))
         (unless view
           (signal 'etaf-runtime-error
                   (list "Companion presentation requires :view" spec)))))))
  spec)

(defun etaf--pres-wrapper-props (host mode &optional beside-count)
  "Return transparent wrapper Ebox props for HOST in companion MODE."
  (let* ((eprops (etaf--host-eprops host))
         (result nil))
    (dolist (key '(:width :min-width :max-width :flex-grow :flex-shrink
                   :flex-basis :align-self :justify-self :grid-column :grid-row))
      (when (plist-member eprops key)
        (let ((val (plist-get eprops key)))
          (when val
            (setq result (plist-put result key val))))))
    (unless (plist-get result :width)
      (setq result (plist-put result :width 'stretch)))
    (pcase mode
      ('companion-after
       (setq result (plist-put result :item-gap '(lh 0))))
      ('companion-beside
       (setq result (plist-put result :grid-template-columns
                               (make-list (1+ (max 1 (or beside-count 1))) '(fr 1))))
       (setq result (plist-put result :gap '((lh 0) (ch 2))))
       (setq result (plist-put result :align-items 'start))))
    result))

(defun etaf--pres-build-pseg (runtime seg container view)
  "Build and mount a `pres' sub-segment for VIEW inside CONTAINER under SEG."
  (let* ((pctx (etaf--ictx-make
                :runtime runtime
                :context (etaf--ictx-context (etaf--seg-ctx seg))))
         (pseg (etaf--seg-make :kind 'pres :src view :ctx pctx
                               :node container :live t)))
    (condition-case err
        (progn
          (etaf--patch-kids pseg (etaf--flatten view) pctx)
          pseg)
      ((error quit)
       (etaf--dispose pseg nil)
       (signal (car err) (cdr err))))))

(defun etaf--pb-detach-node (node)
  "Remove NODE from its Ebox parent when attached."
  (when (and node (ebox-node-parent node))
    (ebox-node-remove node)))

(defun etaf--pb-sync-children (parent desired)
  "Make PARENT hold DESIRED child Ebox nodes in order using remove/insert/move."
  (dolist (child (ebox-node-children parent))
    (unless (memq child desired)
      (ebox-node-remove child)))
  (let ((idx 0))
    (dolist (child desired)
      (let ((cur (ebox-node-parent child)))
        (cond
         ((and (eq cur parent) (= (ebox-node-index child) idx)))
         ((eq cur parent)
          (ebox-node-move child idx))
         (t
          (when cur (ebox-node-remove child))
          (ebox-node-insert parent child idx))))
      (setq idx (1+ idx)))))

(defun etaf--pb-sync-wrappers (runtime seg bucket)
  "Reconcile outer pairing wrappers for `companion-after' and `companion-beside'."
  (let* ((host (etaf--seg-data seg))
         (node (etaf--seg-node seg))
         (beside-slots (cl-loop for c in (etaf--pb-companions bucket)
                                when (eq (etaf--pres-mode c) 'companion-beside)
                                collect (etaf--pres-slot c)))
         (after-slots (cl-loop for c in (etaf--pb-companions bucket)
                               when (eq (etaf--pres-mode c) 'companion-after)
                               collect (etaf--pres-slot c)))
         (old-outer (or (etaf--pb-outer bucket) node))
         (old-grid (etaf--pb-beside-grid bucket))
         (parent (ebox-node-parent old-outer))
         (idx (and parent (ebox-node-index old-outer)))
         (root-level (or (null parent)
                         (eq parent (etaf-runtime-wrapper runtime))))
         (new-outer nil)
         (new-grid nil))
    (cond
     ;; Case 0: no outer companions.
     ((and (null beside-slots) (null after-slots))
      (setq new-outer node new-grid nil))
     ;; Case 1: beside only -> grid is outer.
     ((and beside-slots (null after-slots))
      (setq new-grid (if (and old-grid (eq old-grid old-outer))
                         old-grid
                       (ebox-node-create 'grid nil nil)))
      (ebox-node-set-props new-grid
                           (etaf--pres-wrapper-props host 'companion-beside
                                                     (length beside-slots)))
      (setq new-outer new-grid))
     ;; Case 2: after only -> column is outer.
     ((and (null beside-slots) after-slots)
      (setq new-outer (if (and (etaf--pb-outer bucket)
                               (not (eq (etaf--pb-outer bucket) old-grid)))
                          (etaf--pb-outer bucket)
                        (ebox-node-create 'column
                                          (etaf--pres-wrapper-props host 'companion-after)
                                          nil)))
      (setq new-grid nil))
     ;; Case 3: both beside and after -> column holds [grid, after...].
     (t
      (setq new-grid (if (and old-grid (not (eq old-grid old-outer)))
                         old-grid
                       (ebox-node-create 'grid nil nil)))
      (ebox-node-set-props new-grid
                           (list :width 'stretch
                                 :grid-template-columns
                                 (make-list (1+ (length beside-slots)) '(fr 1))
                                 :gap '((lh 0) (ch 2))
                                 :align-items 'start))
      (setq new-outer (if (and (etaf--pb-outer bucket)
                               (not (eq (etaf--pb-outer bucket) old-grid)))
                          (etaf--pb-outer bucket)
                        (ebox-node-create 'column
                                          (etaf--pres-wrapper-props host 'companion-after)
                                          nil)))))
    ;; Reconcile Ebox parent/child links using remove/insert/move so Ebox
    ;; clears internal layout run pointers cleanly on detached nodes.
    (if (eq new-outer old-outer)
        (cond
         ((and new-grid (eq new-grid new-outer))
          (etaf--pb-sync-children new-grid (cons node beside-slots)))
         (new-grid
          (etaf--pb-sync-children new-grid (cons node beside-slots))
          (etaf--pb-sync-children new-outer (cons new-grid after-slots)))
         ((not (eq new-outer node))
          (etaf--pb-sync-children new-outer (cons node after-slots))))
      ;; Outer identity changed: detach children first via ebox-node-remove,
      ;; then replace old-outer in parent with new-outer.
      (etaf--pb-detach-node node)
      (dolist (s beside-slots) (etaf--pb-detach-node s))
      (dolist (s after-slots) (etaf--pb-detach-node s))
      (when (and old-grid (not (eq old-grid new-grid)))
        (dolist (c (ebox-node-children old-grid)) (ebox-node-remove c)))
      (when (and (etaf--pb-outer bucket)
                 (not (eq (etaf--pb-outer bucket) new-outer))
                 (not (eq (etaf--pb-outer bucket) new-grid)))
        (dolist (c (ebox-node-children (etaf--pb-outer bucket)))
          (ebox-node-remove c)))
      (etaf--pb-detach-node old-outer)
      (when new-grid
        (etaf--pb-sync-children new-grid (cons node beside-slots)))
      (cond
       ((eq new-outer node) nil)
       ((eq new-outer new-grid) nil)
       (new-grid
        (etaf--pb-detach-node new-grid)
        (etaf--pb-sync-children new-outer (cons new-grid after-slots)))
       (t
        (etaf--pb-sync-children new-outer (cons node after-slots))))
      (setf (etaf--pb-outer bucket) (unless (eq new-outer node) new-outer)
            (etaf--pb-beside-grid bucket) new-grid)
      (if root-level
          (etaf--root-dirty runtime)
        (ebox-node-insert parent new-outer idx)))
    (setf (etaf--pb-outer bucket) (unless (eq new-outer node) new-outer)
          (etaf--pb-beside-grid bucket) new-grid)))

(defun etaf--pb-sync-inside (seg bucket)
  "Keep all `companion-inside' slots of BUCKET attached at the tail of SEG."
  (let ((node (etaf--seg-node seg)))
    (when node
      (dolist (c (etaf--pb-companions bucket))
        (when (eq (etaf--pres-mode c) 'companion-inside)
          (let ((slot (etaf--pres-slot c)))
            (unless (eq (ebox-node-parent slot) node)
              (etaf--pb-detach-node slot)
              (ebox-node-insert node slot)))))
      (etaf--pres-pin-companion-inside seg node))))

(defun etaf--pb-sync-override (runtime seg bucket)
  "Activate the top-priority override in BUCKET, or restore original content."
  (let* ((host (etaf--seg-data seg))
         (node (etaf--seg-node seg))
         (tag (etaf--view-node-name (etaf--seg-src seg)))
         (desired (car (etaf--pb-overrides bucket)))
         (prev (etaf--pb-active-override bucket)))
    (if (eq tag 'text)
        (progn
          (setf (etaf--pb-active-override bucket) desired)
          (when node
            (ebox-node-set-text node (etaf--pb-effective-text host bucket))))
      (unless (eq desired prev)
        ;; Temporarily detach companion-inside slots while swapping children.
        (let ((inside-slots
               (cl-loop for c in (etaf--pb-companions bucket)
                        when (eq (etaf--pres-mode c) 'companion-inside)
                        collect (etaf--pres-slot c))))
          (dolist (s inside-slots) (etaf--pb-detach-node s))
          (when (and prev (etaf--pres-seg prev))
            (etaf--dispose (etaf--pres-seg prev) nil)
            (setf (etaf--pres-seg prev) nil))
          (cond
           (desired
            (unless (etaf--pb-holder bucket)
              (let ((orig (ebox-node-children node))
                    (holder (ebox-node-create 'box nil nil)))
                (ebox-node-replace-children node nil)
                (ebox-node-replace-children holder orig)
                (setf (etaf--pb-holder bucket) holder)))
            (ebox-node-replace-children node nil)
            (condition-case err
                (let ((pseg (etaf--pres-build-pseg runtime seg node
                                                   (etaf--pres-view desired))))
                  (setf (etaf--pres-seg desired) pseg
                        (etaf--pb-active-override bucket) desired))
              ((error quit)
               (ebox-node-replace-children node nil)
               (setf (etaf--pb-overrides bucket)
                     (delq desired (etaf--pb-overrides bucket)))
               (setf (etaf--pb-active-override bucket) nil)
               (when-let* ((holder (etaf--pb-holder bucket)))
                 (let ((back (ebox-node-children holder)))
                   (ebox-node-replace-children holder nil)
                   (ebox-node-replace-children node back)
                   (setf (etaf--pb-holder bucket) nil)))
               (etaf--pb-sync-inside seg bucket)
               (signal (car err) (cdr err)))))
           (t
            (setf (etaf--pb-active-override bucket) nil)
            (when-let* ((holder (etaf--pb-holder bucket)))
              (let ((back (ebox-node-children holder)))
                (ebox-node-replace-children node nil)
                (ebox-node-replace-children holder nil)
                (ebox-node-replace-children node back)
                (setf (etaf--pb-holder bucket) nil)))))
          (etaf--pb-sync-inside seg bucket))))))

(defun etaf--pb-remove-structural (runtime seg bucket key)
  "Remove KEY's companion or override entry from BUCKET; return non-nil if removed."
  (let ((comp (cl-find key (etaf--pb-companions bucket) :key #'etaf--pres-key))
        (ov (cl-find key (etaf--pb-overrides bucket) :key #'etaf--pres-key))
        (changed nil))
    (when comp
      (setf (etaf--pb-companions bucket)
            (delq comp (etaf--pb-companions bucket)))
      (when-let* ((pseg (etaf--pres-seg comp)))
        (etaf--dispose pseg nil)
        (setf (etaf--pres-seg comp) nil))
      (etaf--pb-detach-node (etaf--pres-slot comp))
      (if (eq (etaf--pres-mode comp) 'companion-inside)
          (etaf--pb-sync-inside seg bucket)
        (etaf--pb-sync-wrappers runtime seg bucket))
      (setq changed t))
    (when ov
      (setf (etaf--pb-overrides bucket)
            (delq ov (etaf--pb-overrides bucket)))
      (etaf--pb-sync-override runtime seg bucket)
      (setq changed t))
    changed))

(defun etaf--pb-remove-decoration (seg bucket key)
  "Remove KEY's decoration entry from BUCKET; return non-nil if removed."
  (when-let* ((dec (cl-find key (etaf--pb-decorations bucket) :key #'etaf--pres-key)))
    (setf (etaf--pb-decorations bucket)
          (delq dec (etaf--pb-decorations bucket)))
    (let ((host (etaf--seg-data seg))
          (node (etaf--seg-node seg)))
      (when (and node (eq (etaf--view-node-name (etaf--seg-src seg)) 'text))
        (ebox-node-set-text node (etaf--pb-effective-text host bucket))))
    t))

(defun etaf--pb-cleanup-if-empty (runtime seg bucket)
  "Release BUCKET from Host SEG when empty."
  (when (etaf--pb-empty-p bucket)
    (setf (etaf--host-presentation (etaf--seg-data seg)) nil)
    (when (etaf-runtime-presentations runtime)
      (remhash seg (etaf-runtime-presentations runtime)))))

(defun etaf--pres-detach-key (runtime seg key)
  "Remove presentations owned by KEY (or all when KEY is nil) on SEG.
Must run inside `ebox-call-with-batch'.  Return non-nil when anything changed."
  (let* ((host (etaf--seg-data seg))
         (bucket (and host (etaf--host-presentation host))))
    (when bucket
      (let ((changed nil))
        (if (null key)
            (let ((keys (delete-dups
                         (mapcar #'etaf--pres-key (etaf--pb-all-entries bucket)))))
              (dolist (k keys)
                (when (etaf--pb-remove-decoration seg bucket k) (setq changed t))
                (when (etaf--pb-remove-structural runtime seg bucket k) (setq changed t))))
          (when (etaf--pb-remove-decoration seg bucket key) (setq changed t))
          (when (etaf--pb-remove-structural runtime seg bucket key) (setq changed t)))
        (etaf--pb-cleanup-if-empty runtime seg bucket)
        (when changed
          (etaf--runtime-changed runtime)
          t)))))

(defun etaf--pres-ensure-bucket (runtime seg)
  "Return or create the presentation bucket for Host SEG in RUNTIME."
  (let* ((host (etaf--seg-data seg))
         (bucket (etaf--host-presentation host))
         (table (or (etaf-runtime-presentations runtime)
                    (setf (etaf-runtime-presentations runtime)
                          (make-hash-table :test #'eq)))))
    (unless bucket
      (setq bucket (etaf--pb-make))
      (setf (etaf--host-presentation host) bucket))
    (puthash seg t table)
    bucket))

(defun etaf--pres-apply-1 (runtime seg key spec)
  "Apply presentation SPEC owned by KEY onto Host SEG in RUNTIME.
Must run inside `ebox-call-with-batch'.  Return non-nil when changed."
  (let* ((host (etaf--seg-data seg))
         (node (etaf--seg-node seg))
         (tag (etaf--view-node-name (etaf--seg-src seg))))
    (if (null spec)
        (etaf--pres-detach-key runtime seg key)
      (let ((mode (plist-get spec :mode))
            (text (plist-get spec :text))
            (view (plist-get spec :view))
            (spans (plist-get spec :spans))
            (face (plist-get spec :face))
            (priority (or (plist-get spec :priority) 50)))
        ;; Validate compatibility with Host kind.
        (cond
         ((and (eq mode 'decorate) (not (eq tag 'text)))
          (signal 'etaf-runtime-error
                  (list "Decorate presentation requires a text Host" tag)))
         ((and (eq mode 'override) text (not (eq tag 'text)))
          (signal 'etaf-runtime-error
                  (list "Text override presentation requires a text Host" tag)))
         ((and (eq mode 'override) view (memq tag '(text image)))
          (signal 'etaf-runtime-error
                  (list "View override presentation requires a container Host" tag)))
         ((and (eq mode 'companion-inside) (not (eq tag 'box)))
          (signal 'etaf-runtime-error
                  (list "companion-inside presentation requires a box Host" tag))))
        (pcase mode
          ('decorate
           (if (and (null spans) (null face))
               (let ((bucket (etaf--host-presentation host)))
                 (when (and bucket (etaf--pb-remove-decoration seg bucket key))
                   (etaf--pb-cleanup-if-empty runtime seg bucket)
                   (etaf--runtime-changed runtime)
                   t))
             (let* ((bucket (etaf--pres-ensure-bucket runtime seg))
                    (existing (cl-find key (etaf--pb-decorations bucket)
                                       :key #'etaf--pres-key))
                    (changed nil))
               (if existing
                   (unless (and (equal (etaf--pres-spans existing) spans)
                                (equal (etaf--pres-face existing) face)
                                (= (etaf--pres-priority existing) priority))
                     (setf (etaf--pres-spans existing) (copy-tree spans)
                           (etaf--pres-face existing) (copy-tree face)
                           (etaf--pres-priority existing) priority
                           (etaf--pb-decorations bucket)
                           (etaf--pb-sort (etaf--pb-decorations bucket))
                           changed t))
                 (let ((entry (etaf--pres-make
                               :key key :mode 'decorate :priority priority
                               :seq (cl-incf (etaf-runtime-pres-seq runtime))
                               :face (copy-tree face)
                               :spans (copy-tree spans))))
                   (setf (etaf--pb-decorations bucket)
                         (etaf--pb-sort (cons entry (etaf--pb-decorations bucket)))
                         changed t)))
               (when changed
                 (when node
                   (ebox-node-set-text node (etaf--pb-effective-text host bucket)))
                 (etaf--runtime-changed runtime)
                 t))))
          ('override
           (let* ((bucket (etaf--pres-ensure-bucket runtime seg))
                  (existing-ov (cl-find key (etaf--pb-overrides bucket)
                                        :key #'etaf--pres-key))
                  (existing-comp (cl-find key (etaf--pb-companions bucket)
                                          :key #'etaf--pres-key)))
             ;; Switching key from companion to override drops key's companion.
             (when existing-comp
               (etaf--pb-remove-structural runtime seg bucket key)
               (setq existing-ov nil))
             (cond
              ;; Fast path: text override update in place.
              ((and existing-ov text (etaf--pres-text-override existing-ov))
               (unless (and (equal-including-properties
                             text (etaf--pres-text-override existing-ov))
                            (= (etaf--pres-priority existing-ov) priority))
                 (setf (etaf--pres-text-override existing-ov) text
                       (etaf--pres-priority existing-ov) priority
                       (etaf--pb-overrides bucket)
                       (etaf--pb-sort (etaf--pb-overrides bucket) t))
                 (etaf--pb-sync-override runtime seg bucket)
                 (etaf--runtime-changed runtime)
                 t))
              ;; Fast path: active view override update in place.
              ((and existing-ov view
                    (eq existing-ov (etaf--pb-active-override bucket))
                    (etaf--pres-seg existing-ov))
               (let ((pseg (etaf--pres-seg existing-ov)))
                 (setf (etaf--pres-view existing-ov) view
                       (etaf--pres-priority existing-ov) priority
                       (etaf--seg-src pseg) view)
                 (etaf--patch-kids pseg (etaf--flatten view) (etaf--seg-ctx pseg))
                 (setf (etaf--pb-overrides bucket)
                       (etaf--pb-sort (etaf--pb-overrides bucket) t))
                 (etaf--pb-sync-override runtime seg bucket)
                 (etaf--runtime-changed runtime)
                 t))
              (t
               (when existing-ov
                 (etaf--pb-remove-structural runtime seg bucket key))
               (let ((entry (etaf--pres-make
                             :key key :mode 'override :priority priority
                             :seq (cl-incf (etaf-runtime-pres-seq runtime))
                             :text-override text :view view)))
                 (setf (etaf--pb-overrides bucket)
                       (etaf--pb-sort (cons entry (etaf--pb-overrides bucket)) t))
                 (etaf--pb-sync-override runtime seg bucket)
                 (etaf--runtime-changed runtime)
                 t)))))
          ((or 'companion-inside 'companion-after 'companion-beside)
           (let* ((bucket (etaf--pres-ensure-bucket runtime seg))
                  (existing-comp (cl-find key (etaf--pb-companions bucket)
                                          :key #'etaf--pres-key))
                  (existing-ov (cl-find key (etaf--pb-overrides bucket)
                                        :key #'etaf--pres-key)))
             ;; Switching key from override to companion drops key's override.
             (when existing-ov
               (etaf--pb-remove-structural runtime seg bucket key)
               (setq existing-comp nil))
             (if (and existing-comp
                      (eq (etaf--pres-mode existing-comp) mode)
                      (etaf--pres-seg existing-comp))
                 ;; Fast path: patch companion segment in place.
                 (let ((pseg (etaf--pres-seg existing-comp))
                       (prio-changed (/= (etaf--pres-priority existing-comp) priority)))
                   (setf (etaf--pres-priority existing-comp) priority
                         (etaf--pres-view existing-comp) view
                         (etaf--seg-src pseg) view)
                   (etaf--patch-kids pseg (etaf--flatten view) (etaf--seg-ctx pseg))
                   (when prio-changed
                     (setf (etaf--pb-companions bucket)
                           (etaf--pb-sort (etaf--pb-companions bucket)))
                     (if (eq mode 'companion-inside)
                         (etaf--pb-sync-inside seg bucket)
                       (etaf--pb-sync-wrappers runtime seg bucket)))
                   (etaf--runtime-changed runtime)
                   t)
               ;; New companion or companion mode change for key.
               (when existing-comp
                 (etaf--pb-remove-structural runtime seg bucket key))
               (let* ((slot (ebox-node-create 'column
                                              '(:width stretch :item-gap (lh 0))
                                              nil))
                      (pseg (etaf--pres-build-pseg runtime seg slot view))
                      (entry (etaf--pres-make
                              :key key :mode mode :priority priority
                              :seq (cl-incf (etaf-runtime-pres-seq runtime))
                              :slot slot :seg pseg :view view)))
                 (setf (etaf--pb-companions bucket)
                       (etaf--pb-sort (cons entry (etaf--pb-companions bucket))))
                 (if (eq mode 'companion-inside)
                     (etaf--pb-sync-inside seg bucket)
                   (etaf--pb-sync-wrappers runtime seg bucket))
                 (etaf--runtime-changed runtime)
                 t)))))))))

;;;###autoload
(defun etaf-runtime-set-host-presentations (runtime key updates)
  "Apply presentation UPDATES owned by KEY in mounted RUNTIME in one flush.
KEY is a non-nil symbol identifying the owner.  UPDATES is a list of
\(HOST-ID . SPEC) pairs where HOST-ID is an integer from
`etaf-runtime-host-tree' and SPEC is nil or a presentation plist with `:mode'
\(`decorate', `override', `companion-inside', `companion-after' or
`companion-beside'), optional `:priority' (integer, default 50), and
mode-specific payload (`:spans' / `:face', `:text' or `:view').  Multiple keys
coexist cleanly on the same Host.  Unknown or unmounted HOST-IDs are skipped.
Return the number of Hosts updated."
  (etaf--assert-not-rendering 'set-host-presentations)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (unless (and (symbolp key) key)
    (signal 'etaf-runtime-error (list "Presentation key must be a non-nil symbol" key)))
  (unless (proper-list-p updates)
    (signal 'etaf-runtime-error (list "Presentation updates must be a list" updates)))
  (dolist (entry updates)
    (unless (and (consp entry) (integerp (car entry)))
      (signal 'etaf-runtime-error (list "Invalid presentation update entry" entry)))
    (etaf--pres-validate-spec (cdr entry)))
  (let ((count 0)
        (etaf--in-presentation-mutation t))
    (etaf-call-with-batch
     (lambda ()
       (ebox-call-with-batch
        (lambda ()
          (with-current-buffer (etaf-runtime-buffer runtime)
            (dolist (entry updates)
              (when-let* ((seg (etaf--runtime-seg-by-id runtime (car entry))))
                (when (etaf--pres-apply-1 runtime seg key (cdr entry))
                  (cl-incf count)))))))))
    count))

;;;###autoload
(defun etaf-runtime-set-host-presentation (runtime host-id key spec)
  "Attach or update presentation SPEC owned by KEY on HOST-ID in RUNTIME.
Return non-nil when HOST-ID was live and updated, or nil otherwise."
  (> (etaf-runtime-set-host-presentations runtime key (list (cons host-id spec))) 0))

;;;###autoload
(defun etaf-runtime-clear-presentations (runtime &optional key)
  "Remove attached presentations in mounted RUNTIME, restoring original Hosts.
When KEY is non-nil, remove only presentations owned by KEY without disturbing
other owners; otherwise remove all presentations.  Return the number of Hosts
updated."
  (etaf--assert-not-rendering 'clear-presentations)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (when (and key (not (symbolp key)))
    (signal 'etaf-runtime-error (list "Presentation key must be a symbol or nil" key)))
  (let ((table (etaf-runtime-presentations runtime))
        (count 0)
        (etaf--in-presentation-mutation t))
    (when (and table (> (hash-table-count table) 0))
      (let ((targets nil))
        (maphash (lambda (seg _v)
                   (when (etaf--seg-live seg)
                     (let* ((host (etaf--seg-data seg))
                            (bucket (and host (etaf--host-presentation host))))
                       (when (and bucket
                                  (or (null key)
                                      (cl-some (lambda (e) (eq (etaf--pres-key e) key))
                                               (etaf--pb-all-entries bucket))))
                         (push seg targets)))))
                 table)
        (when targets
          (etaf-call-with-batch
           (lambda ()
             (ebox-call-with-batch
              (lambda ()
                (with-current-buffer (etaf-runtime-buffer runtime)
                  (dolist (seg targets)
                    (when (etaf--pres-detach-key runtime seg key)
                      (cl-incf count)))))))))))
    count))

(provide 'etaf-presentation)
;;; etaf-presentation.el ends here
