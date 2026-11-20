;;; etaf-regions.el --- Named regions, entry resolution and adjacency -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A Host declares `:region', a plist naming a user-addressable functional
;; range such as a sidebar, result list or input area: `:id' is the stable
;; identity, `:label' names it, `:key' is one hint character, `:enter' is the
;; default entry Host, and `:neighbors' maps `:left'/`:right'/`:up'/`:down' to
;; region ids.  Regions nest by Host ancestry; the nearest enclosing region is
;; the parent.
;;
;; `etaf-region-select' is the navigation entry, bound to `M-g' in Runtime
;; buffers.  It shows the declared regions of the current focus scope, then
;; reads one key: a hint key focuses that region's effective entry, an arrow
;; key moves to the sibling region in that direction, and Escape cancels.
;; Declared `:neighbors' win over committed geometry; geometry prefers
;; perpendicular overlap, then axial gap, perpendicular centre distance and
;; document order, and climbs to parent exits when a level has no target.
;;
;; Effective entry resolution prefers the last accepted focus position
;; remembered inside the region, then `:enter', then the region's first
;; eligible stop.  `etaf-region-focus' performs the same jump without the
;; selector, for application direct keys.  Ebox keeps the single focus
;; authority; this module only reads committed Hosts and moves focus through
;; ETAF's public entries.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ebox)
(require 'etaf-runtime)
(require 'etaf-events)

(defconst etaf--regions-direction-events
  '(([left] . left) ([right] . right) ([up] . up) ([down] . down))
  "Arrow events mapped to region direction symbols.")

(defvar etaf-direction-scheme)
(declare-function etaf--keys-scope-root "etaf-keys" (runtime &optional from))

(defconst etaf--regions-vim-direction-events
  '((?h . left) (?j . down) (?k . up) (?l . right))
  "Vim direction characters mapped to region direction symbols.")

(defun etaf--regions-direction-of (event)
  "Return the direction EVENT selects under the active scheme, or nil."
  (or (cdr (assoc event etaf--regions-direction-events))
      (when (eq etaf-direction-scheme 'vim)
        (let ((char (cond ((characterp event) event)
                          ((and (stringp event) (= 1 (length event))) (aref event 0))
                          ((and (vectorp event) (= 1 (length event))) (aref event 0)))))
          (cdr (assoc char etaf--regions-vim-direction-events))))))

(defconst etaf--regions-cancel-event [escape]
  "Event cancelling region selection.")

(defconst etaf--regions-quit-event [?\C-g]
  "Event aborting region selection like a native quit.")

(defconst etaf--regions-declaration-keys '(:id :label :key :enter :neighbors)
  "Allowed properties of a `:region' declaration.")

(defconst etaf--regions-neighbor-directions '(:left :right :up :down)
  "Allowed direction properties of a `:region' `:neighbors' plist.")

(defvar etaf--regions-memory (make-hash-table :test #'eq :weakness 'key)
  "Entry memory: Runtime -> hash of region id -> Host reference.")

(defun etaf--regions-key-char (key)
  "Return KEY's character when KEY is one character, else nil."
  (cond ((characterp key) key)
        ((and (stringp key) (= (length key) 1)) (aref key 0))))

(defun etaf--region-validate (region)
  "Return REGION after validating it as a `:region' declaration.
Signal `etaf-renderer-error' for a malformed plist, an unknown property, a
missing or non-symbol `:id', a `:key' that is not one non-`?' character or a
`:neighbors' entry outside the direction domain."
  (when region
    (unless (and (proper-list-p region) (cl-evenp (length region)))
      (signal 'etaf-renderer-error
              (list ":region must be a property plist with an :id")))
    (let ((rest region))
      (while rest
        (let ((property (pop rest)) (value (pop rest)))
          (unless (memq property etaf--regions-declaration-keys)
            (signal 'etaf-renderer-error
                    (list (format "Unknown :region property %S" property))))
          (pcase property
            (:id
             (unless (symbolp value)
               (signal 'etaf-renderer-error
                       (list ":region :id must be a non-nil symbol"))))
            (:label
             (unless (or (null value) (stringp value))
               (signal 'etaf-renderer-error
                       (list ":region :label must be a string or nil"))))
            (:key
             (unless (or (null value) (etaf--regions-key-char value))
               (signal 'etaf-renderer-error
                       (list ":region :key must be one character")))
             (when (equal (etaf--regions-key-char value) ??)
               (signal 'etaf-renderer-error
                       (list ":region :key cannot be `?'")))
             (when (and (eq etaf-direction-scheme 'vim)
                        (memq (etaf--regions-key-char value) '(?h ?j ?k ?l)))
               (signal 'etaf-renderer-error
                       (list ":region :key cannot use a Vim direction letter"))))
            (:enter
             (unless (or (null value) (symbolp value) (stringp value))
               (signal 'etaf-renderer-error
                       (list ":region :enter must be a Host reference or nil"))))
            (:neighbors
             (unless (and (proper-list-p value) (cl-evenp (length value)))
               (signal 'etaf-renderer-error
                       (list ":region :neighbors must be a direction plist")))
             (let ((plist value))
               (while plist
                 (let ((direction (pop plist)) (target (pop plist)))
                   (unless (memq direction etaf--regions-neighbor-directions)
                     (signal 'etaf-renderer-error
                             (list (format "Unknown :neighbors direction %S"
                                           direction))))
                   (unless (symbolp target)
                     (signal 'etaf-renderer-error
                             (list ":neighbors targets must be region ids"))))))))))
      (unless (plist-get region :id)
        (signal 'etaf-renderer-error (list ":region requires a non-nil :id")))))
  region)

(defun etaf--regions-props (runtime ref)
  "Return committed semantic props of REF in RUNTIME, or nil."
  (when-let* ((seg (etaf--runtime-host-seg runtime ref)))
    (etaf--host-props (etaf--seg-data seg))))

(defun etaf--regions-declaration (runtime ref)
  "Return REF's `:region' declaration in RUNTIME, or nil."
  (when-let* ((props (etaf--regions-props runtime ref)))
    (plist-get props :region)))

(defun etaf--regions-parent-ref (runtime ref declarations)
  "Return the nearest ancestor region reference of REF, or nil.
DECLARATIONS maps region references to their declarations."
  (cl-find-if (lambda (ancestor) (gethash ancestor declarations))
              (etaf-runtime-host-ancestor-refs runtime ref)))

(defun etaf--regions-collect (runtime)
  "Return RUNTIME's committed regions in document order as plists.
Each record carries the declaration fields plus `:ref' and `:parent', the
nearest enclosing region reference (nil at the top level)."
  (let ((declarations (make-hash-table :test #'eq))
        refs)
    (dolist (entry (etaf-runtime-host-props-entries runtime))
      (when (plist-get (cdr entry) :region)
        (puthash (car entry) (plist-get (cdr entry) :region) declarations)
        (push (car entry) refs)))
    (mapcar (lambda (ref)
              (append (list :ref ref
                            :parent (etaf--regions-parent-ref runtime ref declarations))
                      (gethash ref declarations)))
            (nreverse refs))))

(defun etaf--regions-in-scope (runtime &optional from)
  "Return RUNTIME's regions within FROM's or the current keyboard scope."
  (let* ((scope (etaf--keys-scope-root runtime from))
         (regions (etaf--regions-collect runtime)))
    (if (null scope)
        regions
      (cl-remove-if-not
       (lambda (region)
         (when-let* ((node (etaf-runtime-host-node runtime (plist-get region :ref))))
           (or (eq node scope) (ebox-node-ancestor-p scope node))))
       regions))))

(defun etaf--regions-check (regions)
  "Signal `etaf-renderer-error' when REGIONS repeat an id or a hint key."
  (let ((ids (make-hash-table :test #'eq))
        (keys (make-hash-table :test #'eql)))
    (dolist (region regions)
      (let ((id (plist-get region :id)))
        (when (gethash id ids)
          (signal 'etaf-renderer-error
                  (list (format "Duplicate ETAF region id %S" id))))
        (puthash id t ids))
      (when-let* ((char (etaf--regions-key-char (plist-get region :key))))
        (when (gethash char keys)
          (signal 'etaf-renderer-error
                  (list (format "Duplicate ETAF region key %c" char))))
        (puthash char t keys)))))

(defun etaf--regions-table (regions)
  "Return a hash of region reference -> region record for REGIONS."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (region regions)
      (puthash (plist-get region :ref) region table))
    table))

(defun etaf--regions-label (region)
  "Return REGION's display label."
  (let ((label (plist-get region :label)))
    (if (and (stringp label) (not (string-empty-p label)))
        label
      (format "%s" (plist-get region :id)))))

(defun etaf--regions-path (region table)
  "Return REGION's label under its ancestor labels, such as Parent/Child.
TABLE maps region references to records."
  (let ((parent (plist-get region :parent)) labels)
    (while parent
      (let ((record (gethash parent table)))
        (when record
          (push (etaf--regions-label record) labels))
        (setq parent (and record (plist-get record :parent)))))
    (string-join (append labels (list (etaf--regions-label region))) "/")))

(defun etaf--regions-contains-p (runtime region-ref host-ref)
  "Return non-nil when HOST-REF is REGION-REF or inside it in RUNTIME."
  (or (equal region-ref host-ref)
      (member region-ref (etaf-runtime-host-ancestor-refs runtime host-ref))))

(defun etaf--regions-usable-p (runtime ref region-ref)
  "Return non-nil when REF is a committed, enabled entry inside REGION-REF.
A nil REGION-REF only requires the committed, enabled and painted checks."
  (when ref
    (when-let* ((node (etaf-runtime-host-node runtime ref)))
      (let ((props (etaf--regions-props runtime ref)))
        (and (not (plist-get props :disabled))
             (etaf-host-ref-bounds runtime ref)
             (or (null region-ref)
                 (etaf--regions-contains-p runtime region-ref ref)))))))

(defun etaf--regions-containing (runtime regions ref)
  "Return the nearest region in REGIONS containing REF in RUNTIME."
  (when ref
    (cl-loop for ancestor in (cons ref (etaf-runtime-host-ancestor-refs runtime ref))
             thereis (cl-find ancestor regions
                              :key (lambda (region) (plist-get region :ref))
                              :test #'equal))))

(defun etaf--regions-current (runtime regions)
  "Return the nearest region of REGIONS containing the current focus."
  (etaf--regions-containing runtime regions (etaf-focused-host-ref runtime)))

(defun etaf--regions-memory-table (runtime &optional create)
  "Return RUNTIME's region entry memory, creating it when CREATE is non-nil."
  (or (gethash runtime etaf--regions-memory)
      (and create
           (puthash runtime (make-hash-table :test #'eq) etaf--regions-memory))))

(defun etaf--regions-remember (runtime host-ref)
  "Remember HOST-REF as the entry position of each enclosing region."
  (when host-ref
    (let ((table (etaf--regions-memory-table runtime t)))
      (dolist (ref (cons host-ref (etaf-runtime-host-ancestor-refs runtime host-ref)))
        (when-let* ((declaration (etaf--regions-declaration runtime ref)))
          (puthash (plist-get declaration :id) host-ref table))))))

(defun etaf--regions-note-focus (_previous node)
  "Remember NODE's Host as the entry position of its enclosing regions."
  (when-let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
              (ref (and node (etaf-runtime-node-host-ref runtime node))))
    (etaf--regions-remember runtime ref)))

(defun etaf--regions-install (runtime)
  "Track region entry memory in RUNTIME's buffer."
  (with-current-buffer (etaf-runtime-buffer runtime)
    (add-hook 'ebox-focus-change-functions #'etaf--regions-note-focus nil t)))

(defun etaf--regions-uninstall (runtime)
  "Stop tracking entry memory for RUNTIME and release its table."
  (let ((buffer (etaf-runtime-buffer runtime)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'ebox-focus-change-functions #'etaf--regions-note-focus t))))
  (remhash runtime etaf--regions-memory))

(defun etaf--regions-entry-ref (runtime region)
  "Return REGION's remembered or declared entry reference, or nil."
  (let* ((id (plist-get region :id))
         (table (etaf--regions-memory-table runtime))
         (region-ref (plist-get region :ref)))
    (cl-find-if (lambda (candidate)
                  (etaf--regions-usable-p runtime candidate region-ref))
                (list (and table (gethash id table))
                      (plist-get region :enter))
                :test #'equal)))

(defun etaf--regions-focus (runtime region)
  "Focus REGION's effective entry and return the reference, or nil."
  (if-let* ((entry (etaf--regions-entry-ref runtime region)))
      (progn (etaf-focus runtime entry) entry)
    (condition-case nil
        (progn
          (etaf-focus-within runtime (plist-get region :ref))
          (etaf-focused-host-ref runtime))
      (user-error nil))))

(defun etaf--regions-rect (runtime ref)
  "Return REF's committed rectangle as a plist, or nil."
  (when-let* ((node (etaf-runtime-host-node runtime ref))
              (geometry (ebox-node-geometry node)))
    (list :top (plist-get geometry :y)
          :bottom (+ (plist-get geometry :y) (plist-get geometry :height))
          :left (plist-get geometry :x)
          :right (+ (plist-get geometry :x) (plist-get geometry :width)))))

(defun etaf--regions-beyond-p (direction anchor candidate)
  "Return non-nil when CANDIDATE lies beyond ANCHOR in DIRECTION."
  (pcase direction
    ('left (<= (plist-get candidate :right) (plist-get anchor :left)))
    ('right (<= (plist-get anchor :right) (plist-get candidate :left)))
    ('up (<= (plist-get candidate :bottom) (plist-get anchor :top)))
    ('down (<= (plist-get anchor :bottom) (plist-get candidate :top)))))

(defun etaf--regions-overlap-p (direction anchor candidate)
  "Return non-nil when CANDIDATE's perpendicular span meets ANCHOR's."
  (pcase direction
    ((or 'left 'right)
     (< (max (plist-get anchor :top) (plist-get candidate :top))
        (min (plist-get anchor :bottom) (plist-get candidate :bottom))))
    ((or 'up 'down)
     (< (max (plist-get anchor :left) (plist-get candidate :left))
        (min (plist-get anchor :right) (plist-get candidate :right))))))

(defun etaf--regions-gap (direction anchor candidate)
  "Return the axial gap between ANCHOR and CANDIDATE in DIRECTION."
  (pcase direction
    ('left (- (plist-get anchor :left) (plist-get candidate :right)))
    ('right (- (plist-get candidate :left) (plist-get anchor :right)))
    ('up (- (plist-get anchor :top) (plist-get candidate :bottom)))
    ('down (- (plist-get candidate :top) (plist-get anchor :bottom)))))

(defun etaf--regions-centre-distance (direction anchor candidate)
  "Return the perpendicular centre distance between ANCHOR and CANDIDATE."
  (let* ((horizontal (memq direction '(left right)))
         (near (if horizontal :top :left))
         (far (if horizontal :bottom :right))
         (anchor-centre (/ (+ (plist-get anchor near) (plist-get anchor far)) 2))
         (candidate-centre (/ (+ (plist-get candidate near) (plist-get candidate far)) 2)))
    (abs (- anchor-centre candidate-centre))))

(defun etaf--regions-pick (runtime candidates direction anchor order)
  "Return the region record DIRECTION reaches among CANDIDATES.
ANCHOR is the committed anchor rectangle; ORDER maps region references to
document order.  Overlapping candidates win, then the smallest axial gap,
the smallest perpendicular centre distance and the earliest document order."
  (let (ranked)
    (dolist (region candidates)
      (let ((rect (etaf--regions-rect runtime (plist-get region :ref))))
        (when (and rect (etaf--regions-beyond-p direction anchor rect))
          (push (list :region region
                      :overlap (etaf--regions-overlap-p direction anchor rect)
                      :gap (etaf--regions-gap direction anchor rect)
                      :centre (etaf--regions-centre-distance direction anchor rect)
                      :order (gethash (plist-get region :ref) order 1000000))
                ranked))))
    (when-let* ((best (car (sort ranked
                                (lambda (a b)
                                  (cond
                                   ((not (eq (plist-get a :overlap) (plist-get b :overlap)))
                                    (plist-get a :overlap))
                                   ((/= (plist-get a :gap) (plist-get b :gap))
                                    (< (plist-get a :gap) (plist-get b :gap)))
                                   ((/= (plist-get a :centre) (plist-get b :centre))
                                    (< (plist-get a :centre) (plist-get b :centre)))
                                   (t (< (plist-get a :order) (plist-get b :order)))))))))
      (plist-get best :region))))

(defun etaf--regions-anchor-ref (runtime)
  "Return the reference anchoring region geometry: focus, else point."
  (or (etaf-focused-host-ref runtime)
      (etaf-host-ref-at runtime)))

(defun etaf--regions-neighbor (runtime regions direction)
  "Return the id of the region DIRECTION reaches from the current position."
  (let* ((table (etaf--regions-table regions))
         (anchor-ref (etaf--regions-anchor-ref runtime))
         (anchor (and anchor-ref (etaf--regions-rect runtime anchor-ref)))
         (current (etaf--regions-current runtime regions))
         (order (make-hash-table :test #'eq)))
    (cl-loop for region in regions
             for index from 0
             do (puthash (plist-get region :ref) index order))
    (when anchor
      (cl-labels
          ((declared (region)
             (when region
               (let* ((neighbors (plist-get region :neighbors))
                      ;; Directions are symbols; the property keys are keywords.
                      (target (plist-get neighbors (intern (format ":%s" direction)))))
                 (when (and target
                            (cl-find target regions
                                     :key (lambda (item) (plist-get item :id))))
                   target))))
           (search (level)
             (or (declared level)
                 (let* ((parent (and level (plist-get level :parent)))
                        (found
                         (etaf--regions-pick
                          runtime
                          (cl-remove-if-not
                           (lambda (region)
                             (equal (plist-get region :parent) parent))
                           regions)
                          direction anchor order)))
                   (if found
                       (plist-get found :id)
                     (when level
                       (search (gethash parent table))))))))
        (search current)))))

(defun etaf--regions-selector-map (regions)
  "Return the completion map for region selection over REGIONS.
The map completes Escape, `?' and the declared keys so `read-key-sequence'
returns them as complete events instead of consulting unrelated prefixes."
  (let ((map (make-sparse-keymap)))
    (define-key map etaf--regions-cancel-event #'ignore)
    (dolist (event (cons [??] (mapcar #'car etaf--regions-direction-events)))
      (define-key map event #'ignore))
    (dolist (region regions)
      (when-let* ((char (etaf--regions-key-char (plist-get region :key))))
        (define-key map (char-to-string char) #'ignore)))
    map))

(defun etaf--regions-hint (regions current table)
  "Return the hint line for REGIONS with CURRENT marked.
TABLE maps region references to records."
  (let ((parts
         (mapcar
          (lambda (region)
            (let ((char (etaf--regions-key-char (plist-get region :key))))
              (format "%s %s%s"
                      (if char (format "[%c]" char) " · ")
                      (if (equal (plist-get region :ref)
                                 (and current (plist-get current :ref)))
                          "*" "")
                      (etaf--regions-path region table))))
          regions)))
    (format "%s  |  %s  |  ESC 取消"
            (string-join parts "  ")
            (if (eq etaf-direction-scheme 'vim)
                "h/j/k/l 跨区"
              "←→↑↓ 跨区"))))

(defun etaf--regions-select-loop (runtime regions)
  "Read one selection for REGIONS in RUNTIME until it jumps or cancels."
  (let* ((table (etaf--regions-table regions))
         (current (etaf--regions-current runtime regions))
         (map (etaf--regions-selector-map regions))
         (notice nil)
         (done nil))
    (while (not done)
      (message "%s%s" (etaf--regions-hint regions current table)
               (if notice (format "  ·  %s" notice) ""))
      (let ((event (let ((overriding-terminal-local-map map))
                     (read-key-sequence nil))))
        (cond
         ((or (null event)
              (and (vectorp event) (= 0 (length event)))
              (and (stringp event) (= 0 (length event))))
          (setq done t))
         ((or (equal event etaf--regions-quit-event)
              (equal event (string ?\C-g)))
          ;; Native quit: C-g aborts the selection like any prefix.
          (signal 'quit nil))
         ((equal event etaf--regions-cancel-event)
          (setq done t))
         ((equal event "?")
          (setq notice "提示键进入区域；方向键跨区；Escape 取消"))
         ((etaf--regions-direction-of event)
          (let* ((direction (etaf--regions-direction-of event))
                 (target (etaf--regions-neighbor runtime regions direction)))
            (if (null target)
                (setq notice (format "%s 方向没有相邻区域"
                                     (pcase direction
                                       ('left "左") ('right "右")
                                       ('up "上") ('down "下"))))
              (let ((region (cl-find target regions
                                     :key (lambda (item) (plist-get item :id)))))
                (if (and region (etaf--regions-focus runtime region))
                    (setq done t)
                  (setq notice (format "区域 %s 没有可聚焦的入口" target)))))))
         ((and (stringp event) (= (length event) 1))
          (let ((region (cl-find (aref event 0) regions
                                 :key (lambda (item)
                                        (etaf--regions-key-char (plist-get item :key)))
                                 :test #'eql)))
            (if (null region)
                (setq notice (format "%s 不是区域键" (key-description event)))
              (if (etaf--regions-focus runtime region)
                  (setq done t)
                (setq notice (format "区域 %s 没有可聚焦的入口"
                                     (etaf--regions-label region)))))))
         (t
          (setq notice (format "%s 不是区域键" (key-description event)))))))))

;;;###autoload
(defun etaf-region-select (&optional runtime)
  "Select a region of mounted RUNTIME from the keyboard.
Show the declared regions of the current focus scope with their hint keys,
then read one key: a hint key focuses that region's effective entry, an arrow
key moves to the sibling region in that direction, `?' repeats the hint and
Escape cancels.  Other keys change nothing and keep the selector open.  This
is the framework's default `M-g' binding in Runtime buffers."
  (interactive)
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let ((regions (etaf--regions-in-scope runtime)))
    (etaf--regions-check regions)
    (unless regions
      (user-error "No ETAF region is declared in this scope"))
    (etaf--regions-select-loop runtime regions))
  nil)

;;;###autoload
(defun etaf-region-focus (region-id &optional runtime)
  "Focus REGION-ID's effective entry in mounted RUNTIME.
The entry is the last accepted focus position remembered inside the region,
then its declared `:enter' Host, then its first eligible stop.  RUNTIME
defaults to the active Runtime.  Return the focused Host reference; signal
`etaf-event-error' when the region is unknown or has no usable entry."
  (setq runtime (etaf-runtime-require-mounted runtime))
  (let* ((regions (etaf--regions-collect runtime))
         (region (cl-find region-id regions
                          :key (lambda (item) (plist-get item :id))))
         (focused (and region (etaf--regions-focus runtime region))))
    (cond
     ((null region)
      (signal 'etaf-event-error
              (list (format "No ETAF region named %S" region-id))))
     ((null focused)
      (signal 'etaf-event-error
              (list (format "ETAF region %S has no focusable entry" region-id))))
     (t focused))))

(provide 'etaf-regions)
;;; etaf-regions.el ends here
