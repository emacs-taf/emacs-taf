;;; -*- lexical-binding: t; -*-
;;; etaf-screensaver.el --- Idle generative screensavers for Emacs

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0"))
;; Keywords: multimedia, convenience
;; URL: https://github.com/emacs-taf/etaf-screensaver

;;; Commentary:
;; A screensaver, not an editor: only animation is visible.  Keyboard input,
;; mouse movement, a click or wheel input dismisses it and restores the prior
;; window configuration.  Settings belong in Emacs Lisp or Customize.
;;
;; Example:
;;   (require 'etaf-screensaver)
;;   (setq etaf-screensaver-idle-delay 300
;;         etaf-screensaver-program
;;         '(:order shuffle :scenes (matrix snow donut plasma)))
;;   (etaf-screensaver-mode 1)
;;
;; Automatic mode owns one idle watcher and a rearming hook.  A presentation
;; owns one animation timer, a transient input map and an ephemeral buffer;
;; stopping releases all of these.  No child process is started.  This is not
;; a security lock.  Callbacks supplied by scene authors must be pure: they
;; may not create processes/timers or alter editor state.  Reels read their
;; recording at scene creation; the built-in image reader can also prepare
;; the next queued page incrementally in normal animation callbacks.  No
;; other scene callback performs I/O.
;;
;; Only the following declarations are public.  Unlisted symbols are private.
;; See docs/manual.md for playback composition, configuration and scene specs.
;;
;; Function: etaf-screensaver-mode (&optional arg)
;;;###autoload (autoload 'etaf-screensaver-mode "etaf-screensaver" nil t)
;; Toggle automatic presentation after the configured idle interval.
;; Positive ARG enables, nonpositive ARG disables.  Disabling also dismisses
;; an active presentation.  Repeated enabling replaces, not stacks, watchers.
;; The automatic path avoids minibuffer input and unfocused/hidden frames.
;;
;; Function: etaf-screensaver-start (&optional program)
;;;###autoload (autoload 'etaf-screensaver-start "etaf-screensaver" nil t)
;; Present PROGRAM, defaulting to etaf-screensaver-program, in the selected
;; frame and return its buffer.  Starting while active returns the existing
;; buffer.  When no PROGRAM argument is given, a dismissed presentation
;; restarts its current work/page if the effective configuration is unchanged.
;; Its queue, scene seed and program random state continue.  An explicit
;; PROGRAM previews a fresh round without replacing this saved position.
;; Invalid configuration leaves the original windows unchanged;
;; errors during takeover restore them before signaling.  Input is consumed
;; rather than replayed into the restored buffer.
;;
;; Function: etaf-screensaver-stop ()
;;;###autoload (autoload 'etaf-screensaver-stop "etaf-screensaver" nil t)
;; Dismiss the presentation and return nil.  Safe to call repeatedly.
;; Restore windows and mouse tracking; release the Runtime, buffer, animation
;; timer and wake hooks/map.  Automatic mode, if enabled, waits a fresh idle
;; interval.  Disabling the mode releases that watcher too.
;;
;; Function: etaf-screensaver-status ()
;;;###autoload (autoload 'etaf-screensaver-status "etaf-screensaver" nil nil)
;; Return :active and :automatic, plus the active scene's :scene, :buffer name,
;; zero-based :index, :seed, :ticks, :elapsed, :columns, :rows, :frame-rate,
;; copied :params alist and :up-next scene identifiers for this round.
;; Also returns :presentation, :duration (page dwell seconds), :works (the
;; simultaneous scene ids) and :up-next-works (one id list per pending page).
;; :scene and each :up-next entry name the first work on their page; :index
;; counts pages.  :transition-progress is nil outside a page reveal, otherwise
;; its elapsed fraction from zero to one.  Returned lists can be modified
;; without changing playback.
;;
;; Function: etaf-screensaver-scenes ()
;;;###autoload (autoload 'etaf-screensaver-scenes "etaf-screensaver" nil nil)
;; Return registered scene identifiers in registration order.
;;
;; Function: etaf-screensaver-scene-info (scene)
;;;###autoload (autoload 'etaf-screensaver-scene-info "etaf-screensaver" nil nil)
;; Return SCENE's :id, :title, :summary, :tags, :frame-rate and :params.
;; SCENE accepts an identifier, its string name or displayed title.  Callback
;; implementations stay private.  Unknown scenes signal etaf-screensaver-error.
;;
;; Macro: etaf-screensaver-define-scene (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-scene "etaf-screensaver" nil nil)
;; Register a pure callback scene under ID; replace an existing registration
;; in place.  PROPERTIES supplies :create, :step, :render, optional :resize,
;; :title, :summary, :tags, :frame-rate, :duration, :background and :params
;; descriptors.  :duration is the scene's natural length in seconds; a
;; program uses it when neither the item nor scene-options give one, so a
;; recorded work plays once without being cut mid-loop.
;; CREATE returns state, STEP mutates it, RENDER returns row strings or a
;; newline-separated string, and RESIZE returns resized state.  Each receives
;; a context with dimensions, seed, tick, elapsed time, dt and parameter/random
;; accessors; see the macro docstring and manual.  Pointer input always wakes,
;; never enters a scene.  Registrations affect subsequent starts.
;;
;; Function: etaf-screensaver-register-scene (spec)
;;;###autoload (autoload 'etaf-screensaver-register-scene "etaf-screensaver" nil nil)
;; Register inert SPEC data, optionally wrapped as (etaf-scene ...).
;; The plist holds :id, metadata, :params and a nonempty :layers stack.
;; Built-in kinds are rain, sand, particles, field and text.
;; Expressions use a whitelist, never eval.  Invalid specs signal
;; etaf-screensaver-error.  An existing identifier is replaced in place.
;;
;; Function: etaf-screensaver-load-scenes (&optional directories)
;;;###autoload (autoload 'etaf-screensaver-load-scenes "etaf-screensaver" nil t)
;; Load .esc scene files and .esr reel files from DIRECTORIES, defaulting to
;; scene-directories, and return the number loaded.  Later directories
;; override earlier ids.  Bad files report a message and are skipped; other
;; files still load.  Load/reload outside presentation; changes are used by
;; subsequent starts.
;;
;; Function: etaf-screensaver-define-reel-provider (id &rest properties)
;;;###autoload (autoload 'etaf-screensaver-define-reel-provider "etaf-screensaver" nil nil)
;; Register the recorded-animation provider ID with PROPERTIES.
;; PROPERTIES is a plist with :title and :license display strings,
;; :extensions file name suffixes for batch import, :match (lambda (file))
;; recognizing the format and :read (lambda (file)) returning the recording
;; as text frames (:width, :height, :frames, optional :durations seconds
;; per frame and :ansi for SGR runs) or image frames (:image-frames of
;; image file names, optional :image-size and :image-types, a same-length
;; vector of image format symbols). Formats omitted by a provider are detected
;; lazily once per file. Both kinds carry :frame-rate and may add :source, :license and :assets (every file of a multi-file
;; recording).  Re-registering an ID replaces it in place.  The built-in
;; `tte' provider reads Terminal Text Effects recordings and the `frames'
;; provider reads baked image-frame manifests, both without running any
;; tool. Image manifests are bounded to 1 MiB, 7200 local frame basenames,
;; 1–120 fps, dimensions up to 2048 per axis and 2073600 declared pixels.
;; Encoded images are bounded to 16 MiB each and 1 GiB total; paths and
;; symlinks may not escape the bundle. Import trusted images: these bounds
;; do not sandbox Emacs's image decoder. Header validation and import also work
;; without image decoders. A headless buffer can publish image descriptors;
;; visible graphical playback requires a decoder for each format.
;;
;; Function: etaf-screensaver-register-reel (spec)
;;;###autoload (autoload 'etaf-screensaver-register-reel "etaf-screensaver" nil nil)
;; Register the recorded animation described by SPEC as a scene.
;; SPEC is a plist, optionally wrapped as (etaf-reel ...), with :id,
;; :provider and :recording plus optional :title, :summary, :tags, :width,
;; :height, :frame-rate, :frame-count, :source, :license and :background.
;; A relative :recording resolves against the reel file's directory.  The
;; registration retains metadata only.  Playback reads at scene creation,
;; with recent unchanged results cached.  The built-in image provider may
;; validate the next queued page during the current page's normal callbacks;
;; unfinished validation completes at selection.  A next-page failure is
;; reported only when that page is selected, not while the current page plays.
;; Custom providers keep their synchronous :read contract.  Playback follows
;; the recording's own timing.  Recorded text scales its final-frame subject
;; according to etaf-screensaver-reel-text-scale while retaining native
;; surrounding animation; images retain native pixel dimensions when they
;; fit and otherwise scale down proportionally, never enlarging.  When the
;; spec carries :frame-count and :frame-rate the reel registers that full
;; length as its natural :duration, so a program plays the work once instead
;; of cutting it mid-loop.  Invalid
;; specs signal etaf-screensaver-error.  Registering the same :id replaces
;; the previous scene in place.
;;
;; Function: etaf-screensaver-import-recording (file &optional destination)
;;;###autoload (autoload 'etaf-screensaver-import-recording "etaf-screensaver" nil t)
;; Import one recording FILE as a reel and return its report plist.
;; DESTINATION defaults to the user scene directory.  The native recording is
;; copied next to a new .esr reel spec that names its provider, dimensions,
;; frame count and license; it is validated first and never transcoded.
;; The report holds :file, :status `imported', :provider, :kind (text or
;; image), :title, :output, :recording, :width, :height, :image-size,
;; :frame-rate, :frame-count, :colors, :attributes, :license and :source.
;; A multi-file recording is copied into one directory named after the reel.
;; A file no provider recognizes or a recording that fails validation
;; signals etaf-screensaver-error and writes nothing.
;;
;; Function: etaf-screensaver-import-directory (directory &optional destination)
;;;###autoload (autoload 'etaf-screensaver-import-directory "etaf-screensaver" nil t)
;; Import every recording DIRECTORY holds and return a report plist.
;; Candidate files use the extensions registered by reel providers.  An
;; unrecognized file is skipped; a recognized file that fails validation is
;; reported as failed.  Reels are written to DESTINATION (default: the user
;; scene directory), and the report holds :directory, :destination and the
;; :imported, :skipped and :failed lists so callers can audit compatibility,
;; dimensions, color use and license before playing anything.  Register the
;; new reels with etaf-screensaver-load-scenes afterwards.
;;
;; Variable: etaf-screensaver-idle-delay
;; Positive idle seconds before automatic presentation, default 300.
;; Re-enable the mode after changing it to re-arm immediately.
;;
;; Variable: etaf-screensaver-program
;; Repeating program.  The common form is a flat list of scene and pack names,
;; played in order: (setq etaf-screensaver-program '(poems matrix)).  A lone
;; name plays one scene or one pack.  The advanced form is a scene item plist,
;; a pack item or a nested group.  An item has :scene and optional :duration,
;; :frame-rate, :background, :presentation and :params alist.  A pack item
;; (:pack NAME) plays scenes from etaf-screensaver-packs and may override the
;; pack's :order, :count and defaults.  A group has :order
;; sequential/shuffle/random, :scenes children
;; and optional :count selections (default child count) and :presentation
;; inherited by children without an explicit style.  Omitted :order means
;; sequential.  Shuffle draws
;; without replacement within each bag; random allows repeats.  Groups nest
;; to select sequences, hold one style pack for a number of scenes or rotate
;; whole packs.  Consecutive mosaic works within a pack share pages of at
;; most four independent scenes.  Pages never duplicate a work to fill slots;
;; their duration is the longest work's duration, and shorter reels loop.
;;
;; Variable: etaf-screensaver-presentation
;; Nil uses each pack's suggested style (full for standalone works).  Full,
;; card, band or mosaic overrides pack suggestions globally; explicit group
;; or item :presentation settings take priority.  Card insets a thin frame by
;; an even mat of about three line heights, with an ordinary lower-left
;; title/summary on the work's background.
;; Mosaic presents independent
;; works concurrently, not crops of one work; narrow windows stack the tiles.
;;
;; Variable: etaf-screensaver-packs
;; Named style packs: alist of (ID :title TITLE :order ORDER :background COLOR
;; :duration SECONDS :frame-rate RATE :presentation STYLE :params ALIST
;; :scenes (SCENE...)).  Bundled packs cover the shipped
;; scenes; add your own with `add-to-list' after baking or registering
;; scenes.  Playing a pack keeps its works in one visual language.
;;
;; Variable: etaf-screensaver-reel-text-scale
;; Recorded text size: auto (the default) fits a single work's final-frame
;; nonblank subject, filling up to 95% of the width and 70% of the height;
;; concurrent works keep their native overview.  An integer 1 through 24
;; selects a fixed scale for every work; 1 preserves native text.  Small
;; viewports bound the scale.  Graphical SVG-capable Emacs draws vector
;; glyphs without changing line metrics or the framing font; other builds
;; keep native text.  Image recordings are unaffected.  Snapshotted at start;
;; invalid values signal etaf-screensaver-error before window takeover.
;;
;; Variable: etaf-screensaver-transition-duration
;; Reveal seconds between different pages, default 1.2, bounded to 0–5.
;; Zero disables the reveal.  It is capped at half the incoming page's dwell,
;; without changing that dwell or playback order.  The outgoing page retains
;; its colors while new moving content is revealed top-to-bottom; the same
;; page repeated does not transition.  Resize finishes a reveal immediately.
;; Snapshotted at start, independently of content and presentation.
;;
;; Variable: etaf-screensaver-scene-duration
;; Default positive seconds per scene, default 30.  Items override this.
;;
;; Variable: etaf-screensaver-scene-options
;; Per-scene settings, e.g. ((matrix :params ((speed . 5)) :duration 20)
;; (equalizer :presentation full)).  These values override program items,
;; pack values and the global presentation; parameter alists merge by key.
;;
;; Variable: etaf-screensaver-max-frame-rate
;; Positive frame-rate cap up to 120, default 30.  Scene/item rates are capped.
;;
;; Variable: etaf-screensaver-seed
;; Integer for reproducible scene and program choices, or nil for fresh starts.
;;
;; Variable: etaf-screensaver-background
;; Default canvas color, overridden by a scene's own background.
;;
;; Variable: etaf-screensaver-scene-directories
;; Ordered scene directories.  Defaults to bundled scenes and the user's
;; etaf-screensaver/scenes directory.  Load files before starting playback.
;;
;; Error: etaf-screensaver-error
;; Invalid scene or playback configuration.  A start validates before takeover;
;; a runtime failure tears down the presentation and reports the error, disabling
;; automatic mode to avoid an idle error loop.

;;; Code:
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name
                "lisp"
                (file-name-directory
                 (or (and load-file-name
                          (not (string-suffix-p ".eln" load-file-name))
                          (file-directory-p (expand-file-name "lisp" (file-name-directory load-file-name)))
                          load-file-name)
                     (bound-and-true-p byte-compile-current-file)
                     (locate-library "etaf-screensaver")
                     buffer-file-name)))))
(require 'etaf-screensaver-app)

(provide 'etaf-screensaver)
;;; etaf-screensaver.el ends here
