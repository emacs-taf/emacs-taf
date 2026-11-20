# Changelog

## [Unreleased]

### Added

- `etaf-gamekit-install-openspiel` installs the pinned OpenSpiel environment from
  the installed package, so an archive installation can play OpenSpiel games
  without a source checkout. The setup script builds a private cache environment
  with any Python 3.11+, verifies the pinned release by importing it, and
  replaces an older environment only after the new one works.

### Changed

- A missing OpenSpiel runtime now names `M-x etaf-gamekit-install-openspiel`
  instead of the developer command `make engine-openspiel`.

## [0.2.0] - 2026-10-27

### Added

- `etaf-gamekit-install-godot` installs the pinned Godot runtime from the
  installed package in the background, so an archive installation reaches a
  working game without a source checkout. With an explicit executable it
  registers an existing Godot 4.7 or newer instead of downloading. The run
  verifies the release checksum and writes only under the user cache; PATH and
  init files stay untouched. Progress goes to `*ETAF engine install*`.
- The archive ships `native/godot/install-godot.py` with its pinned checksums,
  so archive installations reach a runtime without the development tooling.

### Changed

- A missing Godot runtime now names `M-x etaf-gamekit-install-godot` instead of
  the developer command `make engine`.
- An interrupted download no longer leaves an archive that fails verification
  on every retry: the setup script checks the announced length, refuses a body
  that does not match the pinned SHA-256 and drops a stale cached archive
  before downloading again.
- A presentation mounts as its buffer's ETAF application, so the application
  record owns the lifetime and killing the buffer releases the session. The
  kit requires etaf 0.3.0 and etaf-ui 0.2.0; games keep the mode line they
  had, so the rows a presentation computes do not shift.


- A game session owns state; rendering belongs to exactly one host.
  `etaf-gamekit-start` gained `:display` (default t) and
  `etaf-gamekit-display` mounts the presentation into the session buffer at
  most once. A session started with `:display nil` keeps its buffer unmounted
  so a host window renders that one instance, and publications no longer
  depend on the session buffer having a Runtime.

### Fixed

- Frame-canvas image release declares `image-flush` to the byte compiler, so
  Emacs 29/30 builds no longer report the function as unknown while the
  runtime `require 'image` keeps it available.
- Frame-canvas image release requires the built-in `image` library, so
  `image-flush` is known at byte-compilation time and available at runtime on
  a fresh installation.
- JSON configuration validation marks its serialization check as side-effect
  only, avoiding an unused-value byte-compiler warning on Emacs 29 and 30.
- Godot applies queued commands before physics and flushes a tick's ordered
  replies together, allowing combined controls to share presentation work.
- Streamed states no longer incur another full publication delay when the
  previous rate window has already elapsed.
- Large flat native observation arrays no longer exhaust Lisp evaluation depth
  while copying data for validators and views.

### Added

- Native frame publication: `etaf-gamekit-frame-canvas` shows a canvas
  published as per-line PNG strips, replacing only the rows whose publication
  id changed and falling back to caller text on text displays. Godot projects
  publish strips through the shared `native/godot/frame_strips.gd`, loaded from
  the bridge directory exposed as `Engine.get_meta("gamekit_native_dir")`.
- Godot projects can select `gamekit/observation_hz` from 1 to 60 for autonomous
  state updates; existing projects retain the 20 Hz default.
- OpenSpiel games support bounded undo/redo, including chance outcomes and the
  acting player's perspective. Reset accepts an explicit seed for a new deal.
- The OpenSpiel adapter advertises a `bot` operation that plays one move for the
  side to move: a time-bounded alpha-beta search for xiangqi, and a uniform
  random policy for any turn-based kernel. `undo` and `redo` accept a `:count`
  so a frontend can restore a whole local round in one step.

### Changed

- Game applications now live in independent repositories under `etaf-games`,
  not in this framework's examples. Install `etaf-salvage`, require that feature
  and use `etaf-salvage-open` in place of the bundled `salvage` example.

- OpenSpiel snapshots use format 2 to preserve undo/redo history. Format 1
  snapshots from the initial development version are rejected; finish those
  sessions with that version before upgrading. Other backend snapshots are
  unchanged.
