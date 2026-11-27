# Changelog

All notable user-visible changes to `etaf-install` are documented in this file.

## [Unreleased]

### Changed

- Extracted `etaf-install` from the workspace root into a dedicated multi-file
  package under `packages/etaf-install/` with modular `lisp/` libraries
  (`etaf-install-catalog`, `etaf-install-native`, `etaf-install-doctor`,
  `etaf-install-manage`). Changes to the workspace root README or CHANGELOG no
  longer alter `etaf-install` archive bytes.
- Loaded target metadata and `system_tools` dynamically from the archive's
  `manifest.json` `catalog` map when available, retaining the curated built-in
  catalog for offline use and older archives.

## [0.2.35] - 2026-06-21

### Changed

- Curated target catalog and prebuilt native module auto-installation for the
  ETAF framework, extensions, applications and games.
- Earlier installer history before package extraction is preserved in the
  workspace root changelog.
