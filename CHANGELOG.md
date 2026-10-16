# Changelog

## [Unreleased]

### Added

- Gallery usage panels provide the public signature, parameter defaults,
  constraints and callback arguments for all 63 components, together with
  runnable examples shared with their live previews. References come from
  the installed UI entry, without a manual-package dependency.

### Changed

- Application and game help entries now share searchable, read-only help inside
  the existing application buffer. `?`, existing help commands and help buttons
  no longer split a window or open a separate help page. Search follows the
  application's Theme and adapts between two columns and one scrolling column.
- Modal dialogs and drawers request dismissal when their backdrop is clicked.
  Clicking inside keeps them open and never activates covered controls. Escape
  leaves search editing before closing help; dismissal restores the surviving
  opening focus and scroll position without resetting application state.
- Upgrade the framework packages and their consumers together using the recorded
  revisions. Custom applications should declare bindings with `:keys`, contribute
  non-binding notes through `:help`, and invoke `etaf-help` rather than override
  `?` or manage a separate help buffer. `etaf-help` returns the application
  buffer; `M-x etaf-palette` remains the separate command-execution interface.
  Opening help preserves each application's declared playback or pause policy;
  screensaver input still wakes the display instead of opening help.

### Fixed

- Catalog selection changes paint without shifting labels or resizing controls.
  Disclosure arrows, calendar columns and multi-row overview previews retain
  their intended alignment and visibility.
- Slider arrows stay on valid step-aligned values at a non-step maximum. Range
  honors its inline thickness while preserving row height and retained updates;
  the Gallery Splitter scales gestures using its actual pane width.
- Fresh mounts publish their entire root even when reusing a previously laid-out
  tree. Stable overlays preserve local damage, and retained line publication
  avoids replacing unchanged text and its native positions.
- Shared backdrops dim self-contained PNG, JPEG and SVG images when native SVG
  rendering is available, preserving transparency, vector sharpness, slices and
  geometry. Unsupported formats and file-only image descriptors retain their
  original pixels rather than disappearing.
- Reopening help repaints the backdrop even when its geometry is unchanged.
  Native window scrolling no longer crops the help header or prevents focus and
  scroll restoration after Escape or backdrop dismissal.
