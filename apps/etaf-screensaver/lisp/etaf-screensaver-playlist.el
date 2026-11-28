;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver-playlist.el --- Declarative playback programs

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Validate a finite program tree before taking over a window.  Each group
;; chooses child programs sequentially, in shuffled bags or with replacement.
;; The root repeats after its finite round finishes.  No expression is evaluated.

;;; Code:
(require 'cl-lib)
(require 'etaf-screensaver-model)
(require 'etaf-screensaver-presentation)

(defgroup etaf-screensaver nil
  "Generative, input-dismissed screensavers."
  :group 'multimedia)

(defcustom etaf-screensaver-program
  '(:order sequential
    :scenes ((:pack neon) (:pack space) (:pack poems) (:pack ember)))
  "Playback program, repeated until input dismisses the screensaver.
For the common case, use a flat list of names: a scene name plays that work,
and a pack name expands that pack in place.  For example:

  (setq etaf-screensaver-program (quote (poems matrix)))

A lone name is also accepted.  The advanced forms remain available: a scene
plist holds :scene and optional :duration, :frame-rate, :background and
:params (an alist); a `(:pack NAME)' item plays a pack with :order, :count
and the same overrides; a group holds :order (sequential, shuffle or random),
a nonempty :scenes list of programs and optional :count.  COUNT defaults to
the number of children.  Sequential groups wrap in order; shuffle groups draw
from bags without replacement; random groups allow repeats.  Groups can nest,
so a program can rotate whole packs, hold one pack for a number of scenes,
loop a single work, or mix packs deliberately."
  :type 'sexp :group 'etaf-screensaver)

(defcustom etaf-screensaver-presentation nil
  "Presentation style, independent of the selected works or packs.
Nil uses pack suggestions, or full for ungrouped works.  An explicit style
replaces pack suggestions; an item's or group's :presentation overrides it.
`full' fills the canvas; `card' insets a thin frame by an even mat of about
three line heights, with a lower-left title and summary.  `band' adds a cinema
strip and clock, and `mosaic' plays
consecutive works in independent tiles.
A mosaic page has at most four works and never pads by duplicating a work."
  :type '(choice (const :tag "Pack suggestions" nil)
                 (const :tag "Full window" full)
                 (const :tag "Gallery card" card)
                 (const :tag "Cinema band" band)
                 (const :tag "Mosaic wall" mosaic))
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-reel-text-scale 'auto
  "Scale recorded text in graphical frames without enlarging image reels.
`auto' fills up to 95% of the work width and 70% of its height with the
single work's final nonblank subject, capped at 24 cells per glyph
dimension; concurrent works keep their native overview.  An integer from
1 to 24 chooses a fixed scale for every work; 1 keeps native text.  Small
viewports bound that scale.  Terminals and graphical builds without SVG
keep native text.  Settings are snapshotted at start."
  :type '(choice (const :tag "Fit the text subject" auto) integer)
  :group 'etaf-screensaver)

(defcustom etaf-screensaver-transition-duration 1.2
  "Seconds for a gentle top-to-bottom reveal between different pages.
Zero disables transitions.  The old page keeps its colors while the new
work moves underneath the reveal; there is no blank or recolored interval.
The reveal is capped at half the incoming page's dwell time.  Repeating the
same page does not transition.  This setting is independent of the works,
layout and order, and is snapshotted when presentation starts."
  :type 'number :group 'etaf-screensaver)

(defcustom etaf-screensaver-scene-duration 30
  "Default seconds spent on each scene; individual program items override it."
  :type 'number :group 'etaf-screensaver)

(defcustom etaf-screensaver-scene-options nil
  "Per-scene settings, such as ((matrix :params ((speed . 5)) :duration 20)).
Each entry is a scene identifier followed by :duration, :frame-rate,
:presentation and/or :params.  These values override program items, pack
values and the global presentation; parameter alists merge.  Changes take
effect at the next start.  Invalid options fail before takeover."
  :type 'sexp :group 'etaf-screensaver)

(defcustom etaf-screensaver-max-frame-rate 30
  "Maximum frames per second, including a scene's requested frame rate."
  :type 'number :group 'etaf-screensaver)

(defcustom etaf-screensaver-background "#05070B"
  "Canvas background when a scene does not specify its own."
  :type 'color :group 'etaf-screensaver)

(defcustom etaf-screensaver-seed nil
  "Integer seed for repeatable playback, or nil for a fresh seed at each start."
  :type '(choice (const :tag "Fresh each time" nil) integer)
  :group 'etaf-screensaver)

(defun etaf-screensaver--check-plist (value keys label)
  "Validate VALUE against KEYS, using LABEL in errors."
  (unless (and (proper-list-p value) (zerop (% (length value) 2)))
    (etaf-screensaver--fail "%s must be an even plist" label))
  (let ((tail value) seen)
    (while tail
      (let ((key (pop tail)))
        (pop tail)
        (unless (and (memq key keys) (not (memq key seen)))
          (etaf-screensaver--fail "%s has an unknown or duplicate key: %s" label key))
        (push key seen)))))

(defun etaf-screensaver--parameter-key (key)
  "Normalize parameter KEY, accepting symbols and equivalent keywords."
  (if (keywordp key) (intern (substring (symbol-name key) 1)) key))

(defun etaf-screensaver--parameters (scene overrides)
  "Return validated parameter values for SCENE with OVERRIDES."
  (unless (proper-list-p overrides)
    (etaf-screensaver--fail "Scene parameters must be an alist"))
  (let ((descriptors (etaf-screensaver--scene-params scene)) values seen)
    (dolist (entry overrides)
      (unless (and (consp entry) (symbolp (car entry)))
        (etaf-screensaver--fail "Invalid parameter entry: %s" entry))
      (let* ((key (etaf-screensaver--parameter-key (car entry)))
             (descriptor (cl-find key descriptors :key (lambda (p) (plist-get p :key)))))
        (unless descriptor
          (etaf-screensaver--fail "Unknown parameter %s for %s" key (etaf-screensaver--scene-id scene)))
        ;; Earlier entries have precedence (item, per-scene default).
        (unless (memq key seen)
          (etaf-screensaver--param-validate
           (plist-put (copy-sequence descriptor) :default (cdr entry))
           (etaf-screensaver--scene-id scene))
          (push key seen)
          (push (cons key (cdr entry)) values))))
    (dolist (descriptor descriptors)
      (let ((key (plist-get descriptor :key)))
        (unless (assq key values)
          (push (cons key (plist-get descriptor :default)) values))))
    values))

(defun etaf-screensaver--program-item (program &optional presentation)
  "Validate scene PROGRAM with inherited PRESENTATION and return its settings."
  (let* ((id (if (symbolp program) program (plist-get program :scene)))
         (scene (etaf-screensaver--scene id))
         (defaults (cdr (assq id etaf-screensaver-scene-options)))
         (item (if (symbolp program) nil program)))
    (etaf-screensaver--check-plist item '(:scene :duration :frame-rate :params :background
                                                 :presentation :pack-title :pack-id)
                                   "Scene item")
    (let ((duration (or (plist-get item :duration) (plist-get defaults :duration)
                        (etaf-screensaver--scene-duration scene)
                        etaf-screensaver-scene-duration))
          (rate (or (plist-get item :frame-rate) (plist-get defaults :frame-rate)
                    (etaf-screensaver--scene-frame-rate scene)))
          (presentation (or (plist-get defaults :presentation)
                            (plist-get item :presentation) presentation
                            etaf-screensaver-presentation 'full)))
      (unless (memq presentation etaf-screensaver--presentation-styles)
        (etaf-screensaver--fail "Presentation must be full, card, band or mosaic"))
      (unless (and (numberp duration) (> duration 0) (< duration 86401))
        (etaf-screensaver--fail "Scene duration must be positive and at most one day"))
      (unless (and (numberp rate) (> rate 0) (<= rate 120))
        (etaf-screensaver--fail "Frame rate must be positive and at most 120"))
      (list :scene id :definition scene
            :background (or (plist-get item :background)
                            (etaf-screensaver--scene-background scene)
                            etaf-screensaver-background)
            :presentation presentation :pack-title (plist-get item :pack-title)
            :pack-id (plist-get item :pack-id)
            :reel-text-scale etaf-screensaver-reel-text-scale
            :duration duration :frame-rate (min rate etaf-screensaver-max-frame-rate)
            :params (etaf-screensaver--parameters
                     scene (append (plist-get item :params) (plist-get defaults :params)))))))

(defcustom etaf-screensaver-packs
  '((neon :title "霓虹合成"
          :order sequential :background "#03050D" :presentation full
          :scenes (tte-beams tte-synthgrid equalizer matrix))
    (space :title "深空"
           :order sequential :background "#010207" :presentation band
           :scenes (tte-blackhole tte-fireworks))
    (poems :title "诗句"
           :order shuffle :background "#F4F1EA" :presentation card
           :scenes (tte-ink-rain tte-ink-river tte-ink-snow-mud
                    poem-qingzhou poem-tiancai poem-lingjue
                    poem-mingyue poem-qingquan poem-genglou
                    poem-qingkong poem-chanjuan poem-caiju
                    poem-luoxia poem-ciqing))
    (ember :title "余烬"
           :order sequential :background "#0A0503" :presentation mosaic
           :scenes (tte-bubbles falling-sand)))
  "Named style packs, each a list of scenes sharing one visual language.
An entry is (ID :title TITLE :order ORDER :background COLOR :duration SECONDS
:frame-rate RATE :params ALIST :scenes (SCENE...)).  A program item `(:pack ID)'
plays the pack; the pack's :order, :background, :duration, :frame-rate and
:params are defaults the item may override.  Packs keep a screensaver round
inside one style; put several pack items in one program to rotate styles
deliberately.  Bundled packs cover the scenes shipped with the application;
users can add their own with `add-to-list' after baking or registering scenes."
  :type 'sexp :group 'etaf-screensaver)

(defconst etaf-screensaver--pack-keys
  '(:title :order :background :duration :frame-rate :params
    :presentation :scenes)
  "Keys accepted in a scene pack.")

(defun etaf-screensaver--pack (id)
  "Return pack ID's validated plist, or signal `etaf-screensaver-error'."
  (let ((pack (cdr (assq id etaf-screensaver-packs))))
    (unless (and pack (proper-list-p pack))
      (etaf-screensaver--fail "Unknown scene pack: %s" id))
    (etaf-screensaver--check-plist pack etaf-screensaver--pack-keys
                                   (format "Scene pack %s" id))
    (let ((scenes (plist-get pack :scenes))
          (order (plist-get pack :order)))
      (unless (and (proper-list-p scenes) scenes (cl-every #'symbolp scenes))
        (etaf-screensaver--fail "Scene pack %s needs a list of scene symbols" id))
      (unless (or (null order) (memq order '(sequential shuffle random)))
        (etaf-screensaver--fail "Scene pack %s :order must be sequential, shuffle or random" id))
      (let ((presentation (plist-get pack :presentation)))
        (unless (or (null presentation)
                    (memq presentation etaf-screensaver--presentation-styles))
          (etaf-screensaver--fail "Scene pack %s has an unknown :presentation" id))))
    pack))

(defun etaf-screensaver--compile-pack (program depth &optional presentation)
  "Expand pack PROGRAM at DEPTH, with inherited PRESENTATION.
Explicit item or group styles precede the global style and pack suggestion."
  (when (> depth 16)
    (etaf-screensaver--fail "Playback groups are nested too deeply"))
  (etaf-screensaver--check-plist program '(:pack :order :count :duration :frame-rate
                                                  :params :background :presentation)
                                 "Pack item")
  (let* ((id (plist-get program :pack))
         (pack (etaf-screensaver--pack id))
         (scenes (plist-get pack :scenes))
         (order (or (plist-get program :order) (plist-get pack :order) 'sequential))
         (count (or (plist-get program :count) (length scenes))))
    (unless (memq order '(sequential shuffle random))
      (etaf-screensaver--fail "Pack order must be sequential, shuffle or random"))
    (unless (and (integerp count) (<= 1 count 1000))
      (etaf-screensaver--fail "A pack needs 1..1000 selections"))
    (list :order order :count count
          :scenes
          (mapcar
           (lambda (scene)
             (let ((item (list :scene scene :pack-title (plist-get pack :title) :pack-id id
                               :presentation (or (plist-get program :presentation) presentation
                                                 etaf-screensaver-presentation
                                                 (plist-get pack :presentation) 'full))))
               (dolist (key '(:duration :frame-rate :background))
                 (let ((value (or (plist-get program key) (plist-get pack key))))
                   (when value (setq item (plist-put item key value)))))
               (let ((params (append (plist-get program :params) (plist-get pack :params))))
                 (when params (setq item (plist-put item :params params))))
               (etaf-screensaver--program-item item)))
           scenes))))

(defun etaf-screensaver--compile-program (program &optional depth presentation)
  "Validate PROGRAM at DEPTH with inherited PRESENTATION into a finite tree."
  (when (> (or depth 0) 16)
    (etaf-screensaver--fail "Playback groups are nested too deeply"))
  (unless (or (symbolp program) (proper-list-p program))
    (etaf-screensaver--fail "A program must be a scene symbol or plist"))
  (cond
   ((and (symbolp program)
         (not (assq program etaf-screensaver--scenes))
         (assq program etaf-screensaver-packs))
    (etaf-screensaver--compile-pack (list :pack program) (or depth 0) presentation))
   ((or (symbolp program) (plist-member program :scene))
    (etaf-screensaver--program-item program presentation))
   ((plist-member program :pack)
    (etaf-screensaver--compile-pack program (or depth 0) presentation))
   ((and (proper-list-p program) program (cl-every #'symbolp program))
    (etaf-screensaver--compile-program
     (list :order 'sequential :scenes program) depth presentation))
   (t
    (etaf-screensaver--check-plist program '(:order :scenes :count :presentation) "Playback group")
    (let ((order (or (plist-get program :order) 'sequential))
          (presentation (or (plist-get program :presentation) presentation))
          (scenes (plist-get program :scenes)))
      (unless (or (null presentation) (memq presentation etaf-screensaver--presentation-styles))
        (etaf-screensaver--fail "Presentation must be full, card, band or mosaic"))
      (unless (memq order '(sequential shuffle random))
        (etaf-screensaver--fail "Group order must be sequential, shuffle or random"))
      (unless (and (proper-list-p scenes) scenes (<= (length scenes) 1000))
        (etaf-screensaver--fail "A group needs a list of 1..1000 children"))
      (let ((count (or (plist-get program :count) (length scenes))))
        (unless (and (integerp count) (<= 1 count 1000))
          (etaf-screensaver--fail "A group needs 1..1000 selections"))
        (list :order order :count count
              :scenes (mapcar (lambda (child)
                                (etaf-screensaver--compile-program child (1+ (or depth 0)) presentation))
                              scenes)))))))

(defun etaf-screensaver--validate-options ()
  "Validate global playback settings before changing any windows."
  (unless (and (numberp etaf-screensaver-max-frame-rate)
               (< 0 etaf-screensaver-max-frame-rate) (<= etaf-screensaver-max-frame-rate 120))
    (etaf-screensaver--fail "Maximum frame rate must be in (0, 120]"))
  (unless (and (numberp etaf-screensaver-transition-duration)
               (<= 0 etaf-screensaver-transition-duration 5))
    (etaf-screensaver--fail "Transition duration must be between 0 and 5 seconds"))
  (unless (or (eq etaf-screensaver-reel-text-scale 'auto)
              (and (integerp etaf-screensaver-reel-text-scale)
                   (<= 1 etaf-screensaver-reel-text-scale 24)))
    (etaf-screensaver--fail "Recorded text scale must be auto or an integer from 1 to 24"))
  (unless (or (null etaf-screensaver-seed) (integerp etaf-screensaver-seed))
    (etaf-screensaver--fail "Seed must be an integer or nil"))
  (unless (proper-list-p etaf-screensaver-scene-options)
    (etaf-screensaver--fail "Scene options must be an alist"))
  (unless (proper-list-p etaf-screensaver-packs)
    (etaf-screensaver--fail "Scene packs must be an alist"))
  (unless (or (null etaf-screensaver-presentation)
              (memq etaf-screensaver-presentation etaf-screensaver--presentation-styles))
    (etaf-screensaver--fail "Presentation must be nil, full, card, band or mosaic"))
  (dolist (entry etaf-screensaver-packs)
    (unless (and (consp entry) (symbolp (car entry)))
      (etaf-screensaver--fail "Invalid scene pack entry")))
  (dolist (entry etaf-screensaver-scene-options)
    (unless (and (consp entry) (symbolp (car entry)))
      (etaf-screensaver--fail "Invalid scene options entry"))
    (etaf-screensaver--check-plist (cdr entry) '(:duration :frame-rate :presentation :params)
                                   "Scene options")
    (etaf-screensaver--program-item (car entry))))

(defun etaf-screensaver--program-round (tree random-state)
  "Choose a finite round from TREE using RANDOM-STATE."
  (let ((remaining 10000) result)
    (cl-labels
        ((visit (node)
           (when (< (cl-decf remaining) 0)
             (etaf-screensaver--fail "A playback round exceeds 10000 nodes"))
           (if (plist-member node :scene)
               (push node result)
             (let* ((children (plist-get node :scenes))
                    (count (length children))
                    bag)
               (dotimes (index (plist-get node :count))
                 (visit
                  (pcase (plist-get node :order)
                    ('sequential (nth (% index count) children))
                    ('random (nth (cl-random count random-state) children))
                    ('shuffle
                     (unless bag (setq bag (copy-sequence children)))
                     (let* ((position (cl-random (length bag) random-state))
                            (chosen (nth position bag)))
                       (setq bag (append (cl-subseq bag 0 position) (nthcdr (1+ position) bag)))
                       chosen)))))))))
      (visit tree))
    (etaf-screensaver--program-pages (nreverse result))))

(defun etaf-screensaver--program-pages (items)
  "Group consecutive mosaic ITEMS into pages, preserving pack boundaries.
A page lasts as long as its longest work; shorter recorded works loop at
native speed.  A partial page contains only the selected works."
  (let (result)
    (while items
      (let ((first (pop items)))
        (if (not (eq (plist-get first :presentation) 'mosaic))
            (push first result)
          (let ((tiles (list first)))
            (while (and items (< (length tiles) 4)
                        (eq (plist-get (car items) :presentation) 'mosaic)
                        (eq (plist-get (car items) :pack-id) (plist-get first :pack-id)))
              (push (pop items) tiles))
            (setq tiles (nreverse tiles))
            (let ((page (copy-sequence first)))
              (setq page (plist-put page :tiles tiles)
                    page (plist-put page :duration (apply #'max (mapcar (lambda (item) (plist-get item :duration)) tiles)))
                    page (plist-put page :frame-rate (apply #'max (mapcar (lambda (item) (plist-get item :frame-rate)) tiles))))
              (push page result))))))
    (nreverse result)))

(provide 'etaf-screensaver-playlist)
;;; etaf-screensaver-playlist.el ends here
