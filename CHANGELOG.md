# Changelog

## Unreleased

### Added

- The archive ships `etaf-posframe` as a framework target, so `M-x etaf-install`
  can install the floating panel host that an application's panels need; the
  menu lists it under Framework and the release gate installs it both ways and
  checks that it can derive a panel palette.

### Changed

- `etaf-install` 0.2.11: the shipped files changed with the archive's package
  list, so the archive serves it under a new version instead of overwriting
  0.2.10.

- `etaf-install` 0.2.8: the shipped files changed with the archive's package
  list, so the archive serves it under a new version instead of overwriting
  0.2.7.

- `etaf-install` 0.2.7 offers the packages other authors publish through the
  archive beside its own targets, in the group and under the label the
  archive states. Its own table now names every package this project
  ships, so no framework or game is filed under applications.

- `etaf-install` 0.2.6: the installer payload changed with the archive's new
  package list, so the archive serves it under a new version instead of
  overwriting 0.2.5.

- `etaf-install` 0.2.5: the installer payload changed with the new package
  versions, so the archive serves it under a new version instead of
  overwriting 0.2.4.

### Changed

- `Package-Requires` states direct dependencies only, and `scripts/check-api.py`
  enforces it: a declaration no source uses, or a provider whose API the
  sources call without declaring it, fails `make check`. Fourteen entries were
  corrected; the archive's Requires column follows their next release.

### Added

- `scripts/changes.py` seals and publishes one cross-repository change.
  `status` reports the checkouts with unsealed work, the commits beyond
  `main@origin` and the stale `workspace.json` pins; `commit -F FILE` runs each
  checkout's own checks, then seals providers before the consumers that call
  them and records the sealed revisions in the root; `publish` verifies
  fast-forward on both mirrors before moving any branch, blocks the consumers
  of a checkout it cannot publish, and resumes with only what a failed push
  left behind.

- The archive can carry packages other authors build with ETAF. `community.json`
  pins one revision of each author's repository with the files to ship, the
  dependencies this archive guarantees and the license; `scripts/community.py
  add`/`update` maintain that registry. `exc` (a spreadsheet inside Emacs, by
  yibie) is the first entry. Community packages are filed under Community on the
  archive page, and every package row now names its author, linking the
  organization or the author's GitHub account.
### Added

- The published package archive states when each package last changed. The
  release build records `updated` in `manifest.json`, the newest commit that
  touched the files a package ships, so publishing a release or changing an
  unrelated file in a repository does not move it. Each package page also shows
  the newest `CHANGELOG.md` entries shipped with that version, the downloaded
  size and file count, and the packages that require it, and the index can be
  filtered by name, summary or requirement. `site/scripts/archive_pages.py`
  generates these pages from an archive alone.
- `M-x etaf-install-manage` lists installed and available ETAF targets and
  offers package.el-backed install, update, remove, open and doctor actions.
  `etaf-install-update`, `etaf-install-remove` and `etaf-install-status`
  expose the same lifecycle to callers. Removal deletes package files only;
  application data, logins and caches stay. `etaf-install` is 0.2.0.
- `M-x etaf-install` now offers `etaf-weread`, `etaf-ncm` and `etaf-tanks`. The
  WeChat Reading and NetEase backends ship inside their packages, and their
  `<package>-doctor` commands report Node.js, Python 3, mpv and the login state;
  the tank game reports the Godot runtime GameKit builds. `etaf-install` is
  0.1.6.

### Fixed

- The ETAF Packages table paints its key summary in the header strip instead of
  right-aligning it on the mode line, where a frame narrower than the summary
  pushed the keys off the right edge; `etaf-install` is 0.2.4.
- `etaf-install` 0.2.1 reports a missing runtime tool with its first remedy
  and no longer overwrites it with a "ready" message.  `etaf-install-manage`
  echoes the remedy in the selected-target line and `?` opens the full doctor.
  `etaf-telega` 0.1.3 points at TDLib installation and
  `M-x telega-server-build`.
- `etaf-install` 0.1.7 registers GNU ELPA for targets whose dependency closure
  uses it, and lets a dependency upgrade a loaded built-in package instead of
  aborting before installation. Installing `etaf-telega` on Emacs 29/30 now
  resolves `compat`, a dependency of MELPA's `transient`, instead of stopping
  with "Package `compat` (version 31.0) is unavailable".
- The installer no longer refuses to install a target because one of its runtime
  tools is missing. Installation prerequisites (Emacs version, the SQLite build a
  package compiles against) still stop it; a target's own required capabilities
  are reported after installation and hold back only the opening step.
- `etaf-gamekit` 0.1.2 marks its JSON configuration validation as side-effect
  only, avoiding an Emacs 29/30 byte-compiler warning during installation.

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
