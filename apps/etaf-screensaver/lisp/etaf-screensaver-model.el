;;; etaf-screensaver-model.el --- Scene registry and descriptors -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; A scene is a data description plus pure callbacks: CREATE builds its state,
;; STEP advances it by one frame, RENDER projects it into canvas rows, and the
;; optional RESIZE callback lets it follow the canvas.  Scene state is caller-owned and a scene never touches buffers,
;; timers, files or the network, so every scene runs headless.
;;
;; Registering a scene is a side effect of loading its file.  The registry
;; keeps display order and re-registering an identifier replaces it in place,
;; so reloading a scene file updates the mounted catalog without reordering.

;;; Code:

(require 'cl-lib)

(define-error 'etaf-screensaver-error "ETAF screensaver error")

(defconst etaf-screensaver--scene-keys
  '(:title :summary :tags :frame-rate :duration :background :params
    :create :step :render :resize)
  "Property keys accepted by `etaf-screensaver-define-scene'.")

(cl-defstruct (etaf-screensaver--scene (:constructor etaf-screensaver--scene-make))
  "Registered description of one generative scene.
ID is the registration symbol; TITLE and SUMMARY are display strings; TAGS is
a list of symbols; FRAME-RATE is the scene's preferred frames per second;
DURATION is the scene's natural length in seconds when it has one (a recorded
reel), so a program can play it once without cutting it mid-loop; BACKGROUND
overrides the canvas color; PARAMS is a list of validated parameter
descriptors; CREATE, STEP, RENDER and RESIZE are the scene callbacks.
REEL-SOURCE is private built-in read-ahead metadata, set only by the reel
registrar and retained with this definition in a compiled program."
  id title summary tags frame-rate duration background params create step render resize reel-source)

(defvar etaf-screensaver--scenes nil
  "Registered scenes in display order, as (ID . SCENE) pairs.")

(defconst etaf-screensaver--param-keys
  '(:key :label :type :default :min :max :step :options)
  "Property keys accepted in a scene parameter descriptor.")

(defun etaf-screensaver--fail (message &rest arguments)
  "Signal `etaf-screensaver-error' with formatted MESSAGE and ARGUMENTS."
  (signal 'etaf-screensaver-error (list (apply #'format message arguments))))

(defun etaf-screensaver--param-validate (param scene-id)
  "Validate one scene parameter descriptor PARAM for SCENE-ID and return it.
A descriptor is a plist with :key, :label, :type and :default; a number also
needs :min, :max and an optional positive :step, a choice needs :options as an
alist of unique keys to labels, and a toggle needs a boolean default."
  (unless (proper-list-p param)
    (etaf-screensaver--fail "Scene %s parameter must be a plist: %S" scene-id param))
  (let ((plist param))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--param-keys)
          (etaf-screensaver--fail "Scene %s parameter has unknown key %S" scene-id key)))))
  (let ((key (plist-get param :key))
        (label (plist-get param :label))
        (type (plist-get param :type))
        (default (plist-get param :default)))
    (unless (symbolp key)
      (etaf-screensaver--fail "Scene %s parameter :key must be a symbol: %S" scene-id key))
    (unless (and (stringp label) (not (equal label "")))
      (etaf-screensaver--fail "Scene %s parameter %s needs a nonempty :label" scene-id key))
    (unless (memq type '(number choice toggle))
      (etaf-screensaver--fail "Scene %s parameter %s :type must be number, choice or toggle: %S"
                              scene-id key type))
    (pcase type
      ('number
       (let ((min (plist-get param :min))
             (max (plist-get param :max))
             (step (or (plist-get param :step) 1)))
         (unless (and (integerp min) (integerp max) (<= min max))
           (etaf-screensaver--fail "Scene %s parameter %s needs integer :min <= :max"
                                   scene-id key))
         (unless (and (integerp step) (> step 0))
           (etaf-screensaver--fail "Scene %s parameter %s :step must be a positive integer"
                                   scene-id key))
         (unless (and (integerp default) (<= min default max)
                      (zerop (% (- default min) step)))
           (etaf-screensaver--fail
            "Scene %s parameter %s :default must be an aligned integer in %d..%d"
            scene-id key min max))))
      ('choice
       (let ((options (plist-get param :options))
             (seen nil))
         (unless (and (proper-list-p options) options
                      (cl-every (lambda (option)
                                  (and (consp option)
                                       (stringp (cdr option))
                                       (not (equal (cdr option) ""))
                                       (not (member (car option) seen))
                                       (push (car option) seen)))
                                options))
           (etaf-screensaver--fail
            "Scene %s parameter %s :options must be an alist of unique keys to labels"
            scene-id key))
         (unless (assoc default options)
           (etaf-screensaver--fail "Scene %s parameter %s :default must be one of :options"
                                   scene-id key))))
      ('toggle
       (unless (booleanp default)
         (etaf-screensaver--fail "Scene %s parameter %s :default must be a boolean"
                                 scene-id key))))
    param))

(defun etaf-screensaver--register (id properties)
  "Register or replace the scene ID described by plist PROPERTIES.
Return the registered scene.  A later registration with the same ID replaces
the description in place, keeping display order."
  (unless (symbolp id)
    (etaf-screensaver--fail "Scene identifier must be a symbol: %S" id))
  (let ((plist properties))
    (while plist
      (let ((key (pop plist)))
        (pop plist)
        (unless (memq key etaf-screensaver--scene-keys)
          (etaf-screensaver--fail "Scene %s has unknown property %S" id key)))))
  (dolist (key '(:create :step :render))
    (unless (functionp (plist-get properties key))
      (etaf-screensaver--fail "Scene %s needs a function for %s" id key)))
  (dolist (key '(:resize))
    (let ((value (plist-get properties key)))
      (unless (or (null value) (functionp value))
        (etaf-screensaver--fail "Scene %s %s must be a function or nil" id key))))
  (let ((title (plist-get properties :title))
        (summary (plist-get properties :summary))
        (tags (plist-get properties :tags))
        (frame-rate (or (plist-get properties :frame-rate) 15))
        (duration (plist-get properties :duration))
        (params (plist-get properties :params)))
    (unless (or (null title) (and (stringp title) (not (equal title ""))))
      (etaf-screensaver--fail "Scene %s :title must be a nonempty string" id))
    (unless (or (null summary) (stringp summary))
      (etaf-screensaver--fail "Scene %s :summary must be a string" id))
    (unless (or (null tags) (proper-list-p tags))
      (etaf-screensaver--fail "Scene %s :tags must be a list" id))
    (unless (and (numberp frame-rate) (> frame-rate 0))
      (etaf-screensaver--fail "Scene %s :frame-rate must be a positive number" id))
    (unless (or (null duration) (and (numberp duration) (> duration 0)))
      (etaf-screensaver--fail "Scene %s :duration must be a positive number" id))
    (unless (or (null params) (proper-list-p params))
      (etaf-screensaver--fail "Scene %s :params must be a list" id))
    (let* ((scene (etaf-screensaver--scene-make
                   :id id
                   :title (or title (symbol-name id))
                   :summary (or summary "")
                   :tags tags
                   :frame-rate frame-rate
                   :duration duration
                   :background (plist-get properties :background)
                   :params (mapcar (lambda (param)
                                     (etaf-screensaver--param-validate param id))
                                   params)
                   :create (plist-get properties :create)
                   :step (plist-get properties :step)
                   :render (plist-get properties :render)
                   :resize (plist-get properties :resize)))
           (keys (mapcar (lambda (param) (plist-get param :key))
                         (etaf-screensaver--scene-params scene))))
      (unless (= (length keys) (length (delete-dups (copy-sequence keys))))
        (etaf-screensaver--fail "Scene %s repeats a parameter :key" id))
      (setf etaf-screensaver--scenes
            (if (assq id etaf-screensaver--scenes)
                (mapcar (lambda (pair)
                          (if (eq (car pair) id) (cons id scene) pair))
                        etaf-screensaver--scenes)
              (append etaf-screensaver--scenes (list (cons id scene)))))
      scene)))

(defmacro etaf-screensaver-define-scene (id &rest properties)
  "Register the scene ID described by PROPERTIES.

PROPERTIES is a plist with these keys:

  :title       display name (defaults to the ID's name)
  :summary     one-line description of what the scene shows
  :tags        list of symbols used for grouping
  :frame-rate  preferred frames per second (default 15)
  :background  canvas color overriding the configured background
  :params      list of parameter descriptors, each a plist with
               :key, :label, :type and :default; a number also takes
               :min, :max, :step, a choice takes :options as an alist
               of keys to labels, and a toggle takes a boolean default
  :create      (lambda (context)) returning the scene's initial state
  :step        (lambda (state context)) advancing the state one frame
  :render      (lambda (state context)) returning the frame as a string
               of newline-separated rows or a list of row strings
  :resize      optional (lambda (state context)) returning a state that
               fits a canvas that changed size; without it the engine
               recreates the state at the same seed

The context plist passed to the callbacks holds :columns, :rows, :seed,
:tick, :elapsed, :dt, :param (a key to value function) and :random (a
function returning a float in [0,1), or an integer below a positive limit).
Callbacks must not create timers or processes, perform I/O or change editor
state; the presentation owns resources and all input dismisses it.

Registering is a file-load side effect; registering the same ID again
replaces the previous description in place."
  (declare (indent 1))
  (let ((plist properties)
        (form nil))
    (while plist
      (let ((key (car plist)))
        (unless (memq key etaf-screensaver--scene-keys)
          (etaf-screensaver--fail "Unknown scene property %S" key))
        (setq form (append form (list key (cadr plist))))
        (setq plist (cddr plist))))
    `(etaf-screensaver--register ',id (list ,@form))))

(defun etaf-screensaver--resolve-scene (scene)
  "Return the identifier SCENE names, or nil when the name is nil.
SCENE may be an identifier, its symbol name or its displayed title."
  (cond
   ((null scene) nil)
   ((and (symbolp scene) (assq scene etaf-screensaver--scenes)) scene)
   ((stringp scene)
    (or (cl-loop for pair in etaf-screensaver--scenes
                 when (or (equal scene (symbol-name (car pair)))
                          (equal scene (etaf-screensaver--scene-title (cdr pair))))
                 return (car pair))
        (intern scene)))
   (t scene)))

(defun etaf-screensaver--scene (id)
  "Return the registered scene named ID.
Signal `etaf-screensaver-error' when no scene is registered."
  (or (cdr (assq id etaf-screensaver--scenes))
      (etaf-screensaver--fail "Unknown scene: %S" id)))

(defun etaf-screensaver-scenes ()
  "Return the registered scene identifiers in display order."
  (mapcar #'car etaf-screensaver--scenes))

(defun etaf-screensaver-scene-info (scene)
  "Return SCENE's public description as a plist.
SCENE is an identifier, its symbol name or its displayed title.  The result
holds :id, :title, :summary, :tags, :frame-rate and :params; the scene's
callbacks stay internal."
  (let* ((id (etaf-screensaver--resolve-scene scene))
         (scene (etaf-screensaver--scene id)))
    (list :id id
          :title (etaf-screensaver--scene-title scene)
          :summary (etaf-screensaver--scene-summary scene)
          :tags (etaf-screensaver--scene-tags scene)
          :frame-rate (etaf-screensaver--scene-frame-rate scene)
          :params (etaf-screensaver--scene-params scene))))

(provide 'etaf-screensaver-model)
;;; etaf-screensaver-model.el ends here
