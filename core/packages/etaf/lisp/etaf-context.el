;;; etaf-context.el --- Inherited Component Context -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Context is the one deliberately inherited dependency environment.  It is
;; attached to Component instances, not to View nodes or global variables.

;;; Code:

(require 'cl-lib)
(require 'etaf-reactive)

(define-error 'etaf-context-error "Invalid ETAF Context operation")

(cl-defstruct (etaf-context
               (:constructor etaf--context-create))
  "One inherited Context frame owned by a Component instance."
  parent
  owner-id
  (values (make-hash-table :test #'eq)))

(defvar etaf--current-context nil
  "Context table of the Component currently being evaluated.")

(defvar etaf--theme-defaults-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Context-keyed cache of validated Theme default plists.

Theme values are immutable for the duration of a render pass.  Keeping the
validated copy by Context frame avoids rebuilding the same semantic palette
for every Host that reads one token, while weak keys let disposed Component
Contexts disappear with their Runtime.")

(defvar etaf--theme-value-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Theme-value identity cache of validated immutable palette snapshots.

Many descendant Context frames can inherit the same reactive Theme value.
Caching the defensive copy by that shared value avoids validating and copying
the complete palette once per consumer while keeping Context dependency reads
unchanged.")

(defvar etaf--context-inject-recorder nil
  "Candidate-local function recording Context provider reads.")

(defconst etaf--context-missing (make-symbol "etaf-context-missing")
  "Unique sentinel used to distinguish an absent Context value.")

(defun etaf-context-copy (context)
  "Return an immutable candidate copy of CONTEXT's local frame."
  (when context
    (let ((values (make-hash-table :test #'eq)))
      (maphash (lambda (key value) (puthash key value values))
               (etaf-context-values context))
      (etaf--context-create :parent (etaf-context-parent context)
                            :owner-id (etaf-context-owner-id context)
                            :values values))))

(defun etaf--context-key (key)
  "Validate and normalize Context KEY."
  (unless (and (symbolp key) (not (keywordp key)) (not (memq key '(nil t))))
    (signal 'etaf-context-error
            (list (format "Context keys must be stable symbols: %S" key))))
  key)

;;;###autoload
(defun etaf-provide (key value)
  "Provide VALUE under stable Context KEY to the current subtree."
  (etaf--assert-not-rendering 'provide-context)
  (unless (etaf-context-p etaf--current-context)
    (error "ETAF provide requires Component setup or render context"))
  (puthash (etaf--context-key key) value
           (etaf-context-values etaf--current-context))
  value)

;;;###autoload
(cl-defun etaf-inject (key &optional default (required-p nil required-p-supplied-p))
  "Return the nearest provided value for KEY.

DEFAULT is returned when KEY is absent.  When REQUIRED-P is non-nil, absence
signals an error.  The optional third argument is explicit so a provided nil
can be distinguished from a missing dependency."
  (let ((key (etaf--context-key key))
        (context etaf--current-context)
        found
        provider
        value)
    (while (and context (not found))
      (let ((candidate (gethash key (etaf-context-values context)
                               etaf--context-missing)))
        (unless (eq candidate etaf--context-missing)
          (setq value candidate
                found t
                provider context)))
      (setq context (etaf-context-parent context)))
    (if found
        (progn
          (when etaf--context-inject-recorder
            (funcall etaf--context-inject-recorder provider key))
          value)
      (if (and required-p-supplied-p required-p)
          (signal 'etaf-context-error
                  (list (format "Missing ETAF Context dependency: %S" key)))
        default))))

(defun etaf--validate-theme-defaults (theme)
  "Validate THEME as a property plist and return a defensive copy.

ETAF deliberately keeps Theme as a Context value rather than another runtime
object.  The convention is a property plist whose entries are defaults for
Hosts in the inherited subtree."
  (unless (and (proper-list-p theme)
               (zerop (% (length theme) 2)))
    (signal 'etaf-context-error
            (list (format "Theme defaults must be keyword/value pairs: %S"
                          theme))))
  (let ((copy nil)
        (tail theme))
    (while tail
      (let ((key (pop tail))
            (value (pop tail)))
        (unless (keywordp key)
          (signal 'etaf-context-error
                  (list (format "Theme default must use a keyword: %S" key))))
        (push key copy)
        (push value copy)))
    (nreverse copy)))

;;;###autoload
(defun etaf-theme-provide (theme)
  "Provide THEME property defaults to the current Component subtree.

THEME is a property plist such as `(:color \"#F4F6FB\" :bgcolor \"#202634\")'.
Defaults use ECSS UA origin, including UA-important precedence over author
importance.  Reactive ref/computed plists remain tracked; invalid resolved
values reject candidate publication."
  (etaf-provide
   'theme
   (if (or (etaf-ref-p theme) (etaf-computed-p theme))
       theme
     (let ((validated (etaf--validate-theme-defaults theme)))
       (puthash validated validated etaf--theme-value-cache)
       validated))))

;;;###autoload
(defun etaf-theme-defaults (&optional default)
  "Return inherited Theme property defaults, or DEFAULT when absent."
  (let* ((theme (etaf-inject 'theme default))
         (value (if (or (etaf-ref-p theme) (etaf-computed-p theme))
                    (etaf-value theme)
                  theme))
         (context etaf--current-context)
         (cached (gethash context etaf--theme-defaults-cache)))
    (if (and cached
             (eq (plist-get cached :source) theme)
             (eq (plist-get cached :value) value)
             (equal (plist-get cached :default) default))
        (plist-get cached :validated)
      (let ((validated
             (if (and (proper-list-p value)
                      (zerop (% (length value) 2)))
                 (or (gethash value etaf--theme-value-cache)
                     (let ((copy (etaf--validate-theme-defaults value)))
                       (puthash value copy etaf--theme-value-cache)
                       copy))
               default)))
        (puthash context
                 (list :source theme :value value :default default
                       :validated validated)
                 etaf--theme-defaults-cache)
        validated))))

(defun etaf--theme-source (&optional default)
  "Return the inherited Theme source, using DEFAULT when none is provided.
This does not read the source's reactive value."
  (etaf-inject 'theme default))

(defun etaf--theme-source-value (source &optional default tracked-p)
  "Return SOURCE Theme value or DEFAULT.
When TRACKED-P is nil, do not attach the read to the current render effect."
  (let ((value
         (if (or (etaf-ref-p source) (etaf-computed-p source))
             (let ((etaf--tracking-enabled-p tracked-p))
               (etaf-value source))
           source)))
    (if (and (proper-list-p value) (zerop (% (length value) 2)))
        value
      default)))

(defun etaf--theme-token-resolve-from-source (value source)
  "Resolve Theme token VALUE from SOURCE without render-effect tracking."
  (if (etaf-theme-token-p value)
      (let ((theme (etaf--theme-source-value source nil nil)))
        (etaf--theme-token-resolve-from-theme value theme))
    value))

;;;###autoload
(defun etaf-theme-value (key &optional default)
  "Return Theme property KEY from inherited defaults, or DEFAULT."
  (let ((theme (etaf-theme-defaults)))
    (if (plist-member theme key)
        (plist-get theme key)
      default)))

;;;###autoload
(defun etaf-theme-token (key &optional default transform)
  "Return a deferred Theme token for a static Component style.

KEY is resolved when ETAF lowers the Component's `:styles' declaration, so a
static rule can use the current inherited Theme without turning every retained
Host into an inline dynamic property.  DEFAULT is used when KEY is absent.
TRANSFORM, when non-nil, is a pure function applied after nested defaults have
resolved; it lets a semantic color token lower to a backend value such as a
border specification without reading Theme during Component render.
The returned list is intentionally data, which also makes it safe to place
directly in a quoted `((SELECTOR PROPERTY VALUE ...) ...)' form."
  (unless (keywordp key)
    (signal 'etaf-context-error
            (list (format "Theme token keys must be keywords: %S" key))))
  (when (and transform (not (functionp transform)))
    (signal 'etaf-context-error
            (list (format "Theme token transform must be callable: %S"
                          transform))))
  (append (list 'etaf-theme-token key default)
          (and transform (list transform))))

;;;###autoload
(defun etaf-theme-token-p (value)
  "Return non-nil when VALUE is a deferred ETAF Theme token."
  (and (proper-list-p value)
       (memq (length value) '(2 3 4))
       (eq (car value) 'etaf-theme-token)
       (keywordp (nth 1 value))
       (or (< (length value) 4) (functionp (nth 3 value)))))

(defun etaf--theme-token-resolve-from-theme (value theme)
  "Resolve token VALUE from already resolved THEME data."
  (if (not (etaf-theme-token-p value))
      value
    (let* ((key (nth 1 value))
           (default (nth 2 value))
           (transform (nth 3 value))
           (resolved
            (if (plist-member theme key) (plist-get theme key) default))
           (resolved
            (if (etaf-theme-token-p resolved)
                (etaf--theme-token-resolve-from-theme resolved theme)
              resolved)))
      (if transform (funcall transform resolved) resolved))))

;;;###autoload
(defun etaf-theme-token-resolve (value)
  "Resolve deferred Theme token VALUE, or return ordinary VALUE unchanged."
  (if (etaf-theme-token-p value)
      (etaf--theme-token-resolve-from-theme value (etaf-theme-defaults))
    value))

;;;###autoload
;;;###autoload
(defun etaf-appearance-mode (&optional override)
  "Return a computed appearance mode that follows the host.
OVERRIDE, when non-nil, is a ref holding `light' or `dark' and wins over the
host, which is what an application's own light/dark switch writes.  The
computed tracks the host appearance, so a Component that reads it re-renders
when the host switches."
  (etaf-computed
   (lambda ()
     (or (and override (etaf-value override))
         (etaf-appearance)))
   :test #'eq))

;;;###autoload
(defun etaf-appearance-provide (appearance)
  "Provide APPEARANCE (`light' or `dark') to the current Component subtree.
A host that renders a surface of a different appearance than its frame (a
light panel inside a dark frame) provides it per surface; `etaf-appearance'
reads the nearest one.  APPEARANCE may be a ref or a computed, so a host that
switches appearance republishes the subtree without re-rendering it."
  (unless (or (memq appearance '(light dark))
              (etaf-ref-p appearance)
              (etaf-computed-p appearance))
    (signal 'etaf-context-error
            (list (format "Appearance must be light, dark, a ref or a computed: %S"
                          appearance))))
  (etaf-provide 'appearance appearance))

;;;###autoload
(defun etaf-appearance ()
  "Return the appearance inherited from the nearest host, or the frame mode.
The value is `light' or `dark'.  A provided ref is read through `etaf-value',
so a Component that calls this function re-renders when the host switches
appearance."
  (let ((value (etaf-inject 'appearance nil)))
    (cond ((or (etaf-ref-p value) (etaf-computed-p value))
           (let ((resolved (etaf-value value)))
             (if (memq resolved '(light dark))
                 resolved
               (etaf-theme-current-mode))))
          ((memq value '(light dark)) value)
          (t (etaf-theme-current-mode)))))

;;;; Surface declaration

(cl-defstruct (etaf-surface (:constructor etaf-surface-create))
  "What mounted content declares about the surface it paints.
THEME is a ref or computed holding the Theme plist the content paints with,
MODE is a ref holding its current appearance mode, and MODES is the ordered
alist of (MODE . LABEL) the content can switch between.  A host that frames
the content creates it, provides it with `etaf-surface-provide' and reads the
result; the content declares its own surface with `etaf-surface-declare'."
  theme mode modes)

(defun etaf--surface-check (surface)
  "Require SURFACE to be a host-created ETAF surface."
  (unless (etaf-surface-p surface)
    (signal 'etaf-context-error
            (list (format "Surface must come from `etaf-surface-create': %S"
                          surface))))
  surface)

;;;###autoload
(defun etaf-surface-provide (surface)
  "Provide SURFACE to the current Component subtree.
SURFACE comes from `etaf-surface-create'.  Content mounted inside reads it
with `etaf-surface-host' and declares what it paints with
`etaf-surface-declare', so a host paints its own chrome the way the content
asks instead of guessing a palette.  The declaration travels downward like
every Context value; the object itself is mutable, and the host keeps its own
reference to read the result after the content mounts."
  (etaf--surface-check surface)
  (etaf-provide 'surface surface))

;;;###autoload
(defun etaf-surface-host ()
  "Return the surface declaration of the nearest host, or nil.
The value is the `etaf-surface' a host provided with `etaf-surface-provide'.
It is nil in a host that does not frame the content, such as an ordinary
application buffer, so an application declares its surface only when it is
there."
  (let ((value (etaf-inject 'surface nil)))
    (when value (etaf--surface-check value))))

;;;###autoload
(cl-defun etaf-surface-declare (surface &key theme mode modes)
  "Declare the content's own surface on host SURFACE.
THEME is a ref or computed holding the Theme plist the content paints with,
MODE a ref holding its current mode symbol, and MODES the ordered alist of
(MODE . LABEL) the content can switch between; LABEL is a string.  A host
paints its frame, title bar and border from THEME and offers MODES as its
switch, so the content's palette and its switch remain one state: the host
writes MODE, the content reads it, and a change on either side repaints both.
Only the keywords given are replaced, so a content may declare its palette
and its modes in separate calls.  An invalid value signals
`etaf-context-error' before anything is stored."
  (etaf--assert-not-rendering 'surface-declare)
  (etaf--surface-check surface)
  (when (and theme (not (or (etaf-ref-p theme) (etaf-computed-p theme))))
    (signal 'etaf-context-error
            (list (format "Surface theme must be a ref or a computed: %S"
                          theme))))
  (when (and mode (not (etaf-ref-p mode)))
    (signal 'etaf-context-error
            (list (format "Surface mode must be a ref: %S" mode))))
  (when modes
    (unless (and (proper-list-p modes)
                 (cl-every (lambda (entry)
                             (and (consp entry) (symbolp (car entry))
                                  (stringp (cdr entry))))
                           modes))
      (signal 'etaf-context-error
              (list (format "Surface modes must be an alist of mode and label: %S"
                            modes)))))
  (when theme (setf (etaf-surface-theme surface) theme))
  (when mode (setf (etaf-surface-mode surface) mode))
  (when modes (setf (etaf-surface-modes surface) modes))
  surface)

(defvar etaf--theme-generation (etaf-ref 0)
  "Counts Emacs theme switches, so appearance consumers re-derive.")

(defvar etaf--theme-timer nil
  "Pending coalesced pass after a theme switch.")

(defun etaf--theme-changed (&rest _)
  "Note that a theme switch may have changed the frame appearance.
`enable-theme-functions' and `disable-theme-functions' report the steps of one
switch, so the pass is coalesced after the current command instead of walking
it once per step."
  (when (timerp etaf--theme-timer)
    (cancel-timer etaf--theme-timer))
  (setq etaf--theme-timer
        (run-at-time 0 nil
                     (lambda ()
                       (etaf-batch
                        (setf (etaf-value etaf--theme-generation)
                              (1+ (etaf-value etaf--theme-generation))))))))

(add-hook 'enable-theme-functions #'etaf--theme-changed)
(add-hook 'disable-theme-functions #'etaf--theme-changed)

(defun etaf-theme-current-mode ()
  "Return the current frame color mode as `light' or `dark'.

This is only the default mode for palette resolution.  An application-owned
Theme toggle should pass its explicit mode to `etaf-theme-resolve-palette'
instead of changing the Emacs frame.  Reading the switch generation makes a
Theme computed or a render that calls this function re-derive after a theme
switch instead of keeping the palette the frame had when it first read it."
  (etaf-value etaf--theme-generation)
  (if (eq (frame-parameter nil 'background-mode) 'dark) 'dark 'light))

(defun etaf--theme-resolve-color (value mode)
  "Resolve one light/dark VALUE for MODE."
  (cond
   ((stringp value) value)
   ((and (consp value)
         (or (stringp (car value)) (null (car value)))
         (or (stringp (cdr value)) (null (cdr value))))
    (if (eq mode 'dark) (cdr value) (car value)))
   ((and (proper-list-p value)
         (or (plist-member value :light) (plist-member value :dark)))
    (if (eq mode 'dark) (plist-get value :dark) (plist-get value :light)))
   ((null value) nil)
   (t
    (signal 'etaf-context-error
            (list (format "Invalid ETAF palette color: %S" value))))))

;;;###autoload
(defun etaf-theme-resolve-palette (palette mode)
  "Resolve semantic PALETTE token specs for explicit MODE.

PALETTE is a keyword plist.  Each value may be a color string, a
`(LIGHT . DARK)' pair, or a `(:light LIGHT :dark DARK)' plist.  MODE is
`light' or `dark'.  The result is an ordinary Theme plist suitable for
`etaf-theme-provide'.  ETAF owns this semantic contract; a renderer-specific
palette package may adapt its own registry into this shape at the boundary."
  (unless (memq mode '(light dark))
    (signal 'etaf-context-error
            (list (format "Theme palette mode must be light or dark: %S"
                          mode))))
  (unless (and (proper-list-p palette)
               (zerop (% (length palette) 2)))
    (signal 'etaf-context-error
            (list (format "Theme palette must be a keyword plist: %S"
                          palette))))
  (let (result)
    (while palette
      (let ((key (pop palette))
            (value (pop palette)))
        (unless (keywordp key)
          (signal 'etaf-context-error
                  (list (format "Theme palette key must be a keyword: %S"
                                key))))
        (push key result)
        (push (etaf--theme-resolve-color value mode) result)))
    (nreverse result)))

(provide 'etaf-context)

;;; etaf-context.el ends here
