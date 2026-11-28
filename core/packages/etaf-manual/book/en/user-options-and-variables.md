# User Options and Variables

Every documented variable, grouped by the chapter that defines it. Each row links to the entry, which gives the accepted values, the default and the scope. A buffer-local variable can hold a different value in each buffer; a process-wide one applies everywhere.

<!-- index: variable; user option; parameter -->

## Images

| Variable | Purpose |
| --- | --- |
| [`ebox-image-converters`](images.md#variable-ebox-image-converters) | Ordered (NAME . FUNCTION) image converters, called only by preparation. |
| [`ebox-image-kitty-protocol`](images.md#variable-ebox-image-kitty-protocol) | Control Kitty terminal graphics protocol use on text frames (`auto`, `t` or nil). |

## Viewport

| Variable | Purpose |
| --- | --- |
| [`ebox-viewport-settle-delay`](viewport.md#variable-ebox-viewport-settle-delay) | Seconds of quiet after the last size change before Ebox reflows. |
| [`ebox-viewport-width`](viewport.md#variable-ebox-viewport-width) | Viewport width in pixels for rendering outside a mount, or nil. |
| [`ebox-viewport-height`](viewport.md#variable-ebox-viewport-height) | Viewport height in lines for rendering outside a mount, or nil. |

## Scrolling

| Variable | Purpose |
| --- | --- |
| [`ebox-scroll-step`](scrolling.md#variable-ebox-scroll-step) | Lines scrolled by one wheel step or `ebox-scroll-down`. |
| [`ebox-swipe-distance`](scrolling.md#variable-ebox-swipe-distance) | Horizontal pixels a gesture travels before it counts as a swipe. |
| [`ebox-swipe-quiet`](scrolling.md#variable-ebox-swipe-quiet) | Seconds without horizontal wheel events that end a swipe gesture; a direction change also ends it immediately. |

## Dragging

| Variable | Purpose |
| --- | --- |
| [`ebox-drag-edge-band`](dragging-and-gestures.md#variable-ebox-drag-edge-band) | Lines and columns from a window edge where a drag reports edge intent. |
| [`ebox-drag-edge-interval`](dragging-and-gestures.md#variable-ebox-drag-edge-interval) | Seconds between `edge` gestures while a drag rests in or past the edge band. |

## Keyboard

| Variable | Purpose |
| --- | --- |
| [`etaf-direction-scheme`](keyboard.md#variable-etaf-direction-scheme) | Direction scheme of the key layer: `arrows` (default) or `vim`. |
| [`etaf-help-view-function`](keyboard.md#variable-etaf-help-view-function) | Optional in-buffer modal help renderer; nil uses the core presentation. |
| [`ebox-buffer-mode-map`](keyboard.md#variable-ebox-buffer-mode-map) | Keymap of mounted Ebox buffers: scrolling, focus navigation and activation. |

## Text Input

| Variable | Purpose |
| --- | --- |
| [`ebox-input-edit-commands`](text-input.md#variable-ebox-input-edit-commands) | Commands that edit the session value when a session `:keymap` binds them. |
| [`etaf-cursor-follows-input-modality`](text-input.md#variable-etaf-cursor-follows-input-modality) | Whether a mounted canvas hides its cursor after a pointer click; nil by default. |
| [`ebox-allow-text-selection`](text-input.md#variable-ebox-allow-text-selection) | Whether a mounted canvas allows native Emacs mark and pointer text selection. |

## Animation

| Variable | Purpose |
| --- | --- |
| [`etaf-animation-easings`](animation.md#variable-etaf-animation-easings) | Alist of `(NAME . FUNCTION)` easing curves from progress to eased progress. |
| [`etaf-animation-interpolators`](animation.md#variable-etaf-animation-interpolators) | Ordered `((PREDICATE . FUNCTION) ...)` conversions consulted before built-in interpolation. |
| [`etaf-animation-color-space`](animation.md#variable-etaf-animation-color-space) | Color space used by `etaf-animation-interpolate`: `rgb` (default) or `oklab`. |
| [`etaf-animation-spring-presets`](animation.md#variable-etaf-animation-spring-presets) | Alist of `(NAME . PLIST)` spring parameter bundles for `etaf-spring`. |
| [`etaf-animation-frame-rate`](animation.md#variable-etaf-animation-frame-rate) | Display clock rate in frames per second for running animations. |
| [`etaf-animation-speed`](animation.md#variable-etaf-animation-speed) | Animation speed multiplier, a positive number; 1.0 is normal speed. |
| [`etaf-animation-paused`](animation.md#variable-etaf-animation-paused) | While non-nil, the shared clock stops advancing. |
| [`etaf-animation-pause-hidden`](animation.md#variable-etaf-animation-pause-hidden) | When non-nil, animations owned by an undisplayed Runtime buffer hold their progress. |
| [`etaf-animation-enabled`](animation.md#variable-etaf-animation-enabled) | Whether animations interpolate over time; t by default. |

## Native Video

| Variable | Purpose |
| --- | --- |
| [`etaf-video-audio`](native-video.md#variable-etaf-video-audio) | Whether new videos play their source's audio track by default. |
| [`etaf-video-audio-volume`](native-video.md#variable-etaf-video-audio-volume) | Default audio volume for new videos, from 0 to 100. |
| [`etaf-video-density-ramp`](native-video.md#variable-etaf-video-density-ramp) | Characters used for one video pixel in the `ascii` render mode. |
| [`etaf-video-display-fps`](native-video.md#variable-etaf-video-display-fps) | Display timer rate in frames per second for new video playback. |
| [`etaf-video-render-backend`](native-video.md#variable-etaf-video-render-backend) | Rendering backend for video frames: `image`, `canvas` or `auto`. |
| [`etaf-video-engine`](native-video.md#variable-etaf-video-engine) | Playback engine for `etaf-video`: `auto`, `mpv` or `ffmpeg`. |
| [`etaf-video-mpv-library`](native-video.md#variable-etaf-video-mpv-library) | Optional explicit path to the `libmpv` shared library. |
| [`etaf-video-ffmpeg-program`](native-video.md#variable-etaf-video-ffmpeg-program) | Name or absolute path of the ffmpeg executable used to decode video. |
| [`etaf-video-ffplay-program`](native-video.md#variable-etaf-video-ffplay-program) | Name or absolute path of the ffplay executable used for audio. |
| [`etaf-video-ffprobe-program`](native-video.md#variable-etaf-video-ffprobe-program) | Name or absolute path of the ffprobe executable used for metadata. |
| [`etaf-video-driver`](applications.md#variable-etaf-video-driver) | Optional video playback driver plist registered by `etaf-media` for decoupled UI consumers. |

## Overlays

| Variable | Purpose |
| --- | --- |
| [`etaf-pip-frame-backend`](applications.md#variable-etaf-pip-frame-backend) | Optional graphical child-frame host backend plist used by `etaf-pip-open`; `etaf-posframe` installs its unified pool automatically. |
| [`etaf-ui-modal-host-function`](ui-overlays.md#variable-etaf-ui-modal-host-function) | Optional child-frame modal host callback for centered `etaf-dialog` modals; `etaf-posframe` installs it automatically. |
| [`etaf-ui-modal-use-child-frame`](ui-overlays.md#variable-etaf-ui-modal-use-child-frame) | Whether centered `etaf-dialog` modals project into a floating child frame on graphical displays; default nil (in-buffer rendering). |

## Icons

| Variable | Purpose |
| --- | --- |
| [`etaf-ui-icon-default-set`](ui-icons.md#variable-etaf-ui-icon-default-set) | The registered fallback style, initially `nerd`; bind or set it before rendering. |
| [`etaf-ui-terminal-icon-set`](ui-icons.md#variable-etaf-ui-terminal-icon-set) | The set consulted first on a text terminal for an SVG request, initially `tty`; set it to a font set the terminal font can draw. |

## Markdown

| Variable | Purpose |
| --- | --- |
| [`etaf-ui-markdown-flavor`](ui-composite-components.md#variable-etaf-ui-markdown-flavor) | Default markdown dialect of `etaf-ui-markdown-parse`. |
| [`etaf-ui-markdown-flavors`](ui-composite-components.md#variable-etaf-ui-markdown-flavors) | Named dialects and the extension flags they enable. |
| [`etaf-ui-markdown-block-extensions`](ui-composite-components.md#variable-etaf-ui-markdown-block-extensions) | Block syntax the parser adds, as recognizers. |
| [`etaf-ui-markdown-inline-extensions`](ui-composite-components.md#variable-etaf-ui-markdown-inline-extensions) | Inline syntax the parser adds, as trigger characters and recognizers. |
| [`etaf-ui-markdown-emoji`](ui-composite-components.md#variable-etaf-ui-markdown-emoji) | Emoji shortcodes the renderer paints. |
| [`etaf-ui-markdown-subscript-table`](ui-composite-components.md#variable-etaf-ui-markdown-subscript-table) | Characters a `~subscript~` run can use. |
| [`etaf-ui-markdown-superscript-table`](ui-composite-components.md#variable-etaf-ui-markdown-superscript-table) | Characters a `^superscript^` run can use. |
| [`etaf-ui-markdown-code-renderers`](ui-composite-components.md#variable-etaf-ui-markdown-code-renderers) | Renderers registered per fenced language. |
| [`etaf-ui-markdown-highlight-languages`](ui-composite-components.md#variable-etaf-ui-markdown-highlight-languages) | Languages whose fenced code is colored with an Emacs mode. |
| [`etaf-ui-markdown-gfm-features`](ui-composite-components.md#variable-etaf-ui-markdown-gfm-features) | The feature plist GitHub Flavored Markdown enables. |

## Parameter Reference

| Variable | Purpose |
| --- | --- |
| [`ekp-alignment`](ekp-parameters.md#variable-ekp-alignment) | Paragraph alignment mode. |
| [`ekp-first-line-indent`](ekp-parameters.md#variable-ekp-first-line-indent) | First-line indentation: pixels, or t for 2 em of the paragraph font. |
| [`ekp-parshape`](ekp-parameters.md#variable-ekp-parshape) | Per-line layout, as a sequence of `(INDENT . WIDTH)` cons cells. |
| [`ekp-line-penalty`](ekp-parameters.md#variable-ekp-line-penalty) | Penalty for each line break. Higher = fewer lines. Default 10. |
| [`ekp-hyphen-penalty`](ekp-parameters.md#variable-ekp-hyphen-penalty) | Penalty for hyphenated breaks. Higher = avoid hyphenation. Default 50. |
| [`ekp-adjacent-fitness-penalty`](ekp-parameters.md#variable-ekp-adjacent-fitness-penalty) | Penalty when adjacent lines differ in tightness by more than one class. |
| [`ekp-consecutive-hyphen-penalty`](ekp-parameters.md#variable-ekp-consecutive-hyphen-penalty) | Base penalty multiplier for consecutive hyphenated lines. |
| [`ekp-last-line-min-ratio`](ekp-parameters.md#variable-ekp-last-line-min-ratio) | Minimum fill ratio for last line (0.0-1.0). |
| [`ekp-last-line-short-penalty`](ekp-parameters.md#variable-ekp-last-line-short-penalty) | Penalty multiplier for underfilled last lines. |
| [`ekp-looseness`](ekp-parameters.md#variable-ekp-looseness) | Target line count offset: 0=optimal, +1=looser (more lines), -1=tighter. |
| [`ekp-ragged-stretch-pixel`](ekp-parameters.md#variable-ekp-ragged-stretch-pixel) | Per-line end-of-line flexibility (pixels) for non-justify alignment. |
| [`ekp-default-cws-stretch-pixel`](ekp-parameters.md#variable-ekp-default-cws-stretch-pixel) | Max stretched pixel of whitespace between CJK chars. |
| [`ekp-kinsoku-profile`](ekp-parameters.md#variable-ekp-kinsoku-profile) | Kinsoku profile used when compiling paragraph break permissions. |
| [`ekp-cjk-no-line-start-extra`](ekp-parameters.md#variable-ekp-cjk-no-line-start-extra) | Custom/Japanese CJK letters that must not start a line. |
| [`ekp-cjk-no-line-end-extra`](ekp-parameters.md#variable-ekp-cjk-no-line-end-extra) | Custom CJK characters that must not end a line. |
| [`ekp-protrusion`](ekp-parameters.md#variable-ekp-protrusion) | Non-nil enables right-edge character protrusion (hanging punctuation). |
| [`ekp-protrusion-ratios`](ekp-parameters.md#variable-ekp-protrusion-ratios) | Alist CLASS → RATIO of the glyph width allowed to protrude. |
| [`ekp-number-unit-suffixes`](ekp-parameters.md#variable-ekp-number-unit-suffixes) | Exact suffixes recognized by the compact number-unit classifier. |
| [`ekp-break-policy`](ekp-parameters.md#variable-ekp-break-policy) | Text property controlling regional break policy. |
| [`ekp-inline-code-policy`](ekp-parameters.md#variable-ekp-inline-code-policy) | Default break policy for automatic inline code spans. |
| [`ekp-token-break-policies`](ekp-parameters.md#variable-ekp-token-break-policies) | Break policies for bounded automatic token classifiers. |
| [`ekp-overlong-token-policy`](ekp-parameters.md#variable-ekp-overlong-token-policy) | Policy for ordinary non-CJK tokens wider than the measure. |
| [`ekp-hyphenation`](ekp-parameters.md#variable-ekp-hyphenation) | Global discretionary hyphenation policy. |
| [`ekp-latin-lang`](ekp-parameters.md#variable-ekp-latin-lang) | Language code for hyphenation (e.g., "en_US", "de_DE"). |
| [`ekp-buffer-measure`](ekp-parameters.md#variable-ekp-buffer-measure) | Measure used for automatic and default manual buffer layout. |
| [`ekp-buffer-margin-pixel`](ekp-parameters.md#variable-ekp-buffer-margin-pixel) | Pixels reserved inside the window body width. |
| [`ekp-buffer-skip-faces`](ekp-parameters.md#variable-ekp-buffer-skip-faces) | Faces whose paragraphs stay verbatim. |
| [`ekp-buffer-inline-faces`](ekp-parameters.md#variable-ekp-buffer-inline-faces) | Faces whose exact spans use `ekp-inline-code-policy`. |
| [`ekp-buffer-skip-predicate`](ekp-parameters.md#variable-ekp-buffer-skip-predicate) | Function called with a paragraph string that should stay verbatim. |
| [`ekp-buffer-mode-policy-alist`](ekp-parameters.md#variable-ekp-buffer-mode-policy-alist) | Mode profiles consulted by automatic and manual buffer layout. |
| [`ekp-auto-justify-lazy-threshold`](ekp-parameters.md#variable-ekp-auto-justify-lazy-threshold) | Buffer size beyond which whole-buffer reflows run visible-first. |
| [`ekp-auto-justify-paragraph-limit`](ekp-parameters.md#variable-ekp-auto-justify-paragraph-limit) | Maximum hard-paragraph characters planned automatically. |
| [`ekp-auto-justify-resize-delay`](ekp-parameters.md#variable-ekp-auto-justify-resize-delay) | Seconds to debounce window resize reflows. |
| [`ekp-auto-justify-tick-budget`](ekp-parameters.md#variable-ekp-auto-justify-tick-budget) | Seconds of work allowed in one lazy reflow tick. |
| [`ekp-auto-justify-native-append`](ekp-parameters.md#variable-ekp-auto-justify-native-append) | Use the loaded native module for automatic live append DP. |
| [`ekp-para-cache-limit`](ekp-parameters.md#variable-ekp-para-cache-limit) | Maximum number of cached paragraphs. |
| [`ekp-use-c-module`](ekp-parameters.md#variable-ekp-use-c-module) | When non-nil, use C dynamic module for DP computation if available. |

## Panels

| Variable | Purpose |
| --- | --- |
| [`etaf-posframe-panel-keys`](posframe-panels.md#variable-etaf-posframe-panel-keys) | Keymap always active while a focusable panel has focus; closes it on `q`, `ESC` and `C-g`. |
| [`etaf-posframe-hide-inactive`](posframe-panels.md#variable-etaf-posframe-hide-inactive) | Hide the panels while Emacs is not the active application. |
| [`etaf-posframe-focus-follows-mouse`](posframe-panels.md#variable-etaf-posframe-focus-follows-mouse) | Move the input focus to a panel the pointer rests on. |
| [`etaf-posframe-border-width`](posframe-panels.md#variable-etaf-posframe-border-width) | Frame border width in pixels when `:border` gives none. |
| [`etaf-posframe-dark-surface`](posframe-panels.md#variable-etaf-posframe-dark-surface) | Neutral near-black a dark panel surface sinks toward. |
| [`etaf-posframe-dark-shade`](posframe-panels.md#variable-etaf-posframe-dark-shade) | How far a dark panel surface sinks toward that near-black. |
| [`etaf-posframe-surface-lift`](posframe-panels.md#variable-etaf-posframe-surface-lift) | How far a light panel surface sinks toward black. |
| [`etaf-posframe-border-focus-strength`](posframe-panels.md#variable-etaf-posframe-border-focus-strength) | How much of the Theme accent a focused border shows. |
| [`etaf-posframe-border-hover-strength`](posframe-panels.md#variable-etaf-posframe-border-hover-strength) | How much of the Theme accent a hovered border shows. |
| [`etaf-posframe-default-width`](posframe-panels.md#variable-etaf-posframe-default-width) | Content columns of a new panel without `:width`. |
| [`etaf-posframe-default-max-height`](posframe-panels.md#variable-etaf-posframe-default-max-height) | Maximum content lines of a new panel without `:height`. |
| [`etaf-posframe-move-step`](posframe-panels.md#variable-etaf-posframe-move-step) | Character cells `etaf-posframe-move` moves without a step count. |
| [`etaf-posframe-resize-step`](posframe-panels.md#variable-etaf-posframe-resize-step) | Columns or rows `etaf-posframe-resize` changes without a step count. |
| [`etaf-posframe-apps`](posframe-applications.md#variable-etaf-posframe-apps) | Registered applications as `(ID . PLIST)` records, in registration order. |
| [`etaf-posframe-app-map`](posframe-applications.md#variable-etaf-posframe-app-map) | Keymap with one binding per registered shortcut. |
| [`etaf-posframe-app-repeat-delay`](posframe-applications.md#variable-etaf-posframe-app-repeat-delay) | Seconds during which a repeated app toggle is ignored. |

## Performance Engineering

| Variable | Purpose |
| --- | --- |
| [`etaf-performance-max-records`](performance-engineering.md#variable-etaf-performance-max-records) | Maximum completed operations retained by the recorder. |

## Notes

- In EKP a parameter can come from three places. A buffer-local value wins over a matching mode profile, which wins over the global variable; the entry for each parameter says how it is read.
- Some variables are read every time the subsystem runs, so a change takes effect from the next key press or the next frame; others are captured when a new video, animation or session starts. The entry says which.
- `ebox-buffer-mode-map` holds a keymap and `ebox-input-edit-commands` a command list; the other rows hold data values.
