# Changelog

All notable user-visible changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `etaf-pomodoro-open` replaces `etaf-pomodoro-start`, so the command that
  presents the timer follows the name every other ETAF application uses and
  the installer can open it.  Update bindings and scripts that call
  `etaf-pomodoro-start`; the arguments are unchanged.

## [0.1.0]

### Added

- A focus timer as an ETAF application: `etaf-pomodoro-start` opens one window
  through `etaf-app-open`, and `etaf-pomodoro-create` + `etaf-pomodoro-view`
  mount the same session in a floating panel or any other host.
- Three styles (`minimal`, `ring`, `card`) that share one four-row body, so a
  panel keeps its size when the style changes.
- Keys `p` (start or pause), `r` (reset), `+` (five more minutes) and `t`
  (next style) on the surface, with `q` closing the standalone window.
- The palette follows the appearance the host provides and the Emacs theme
  otherwise; the timer paints no border of its own, so a panel border stays one
  pixel wide on every side.
- `etaf-pomodoro-default-minutes` sets the focus length of a session created
  without an explicit `:minutes`.
