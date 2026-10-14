# Changelog

## [Unreleased]

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

- Shared backdrops dim self-contained PNG, JPEG and SVG images when native SVG
  rendering is available, preserving transparency, vector sharpness, slices and
  geometry. Unsupported formats and file-only image descriptors retain their
  original pixels rather than disappearing.
- Reopening help repaints the backdrop even when its geometry is unchanged.
  Native window scrolling no longer crops the help header or prevents focus and
  scroll restoration after Escape or backdrop dismissal.
