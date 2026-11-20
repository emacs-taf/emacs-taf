# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The studio runs as an ETAF application: its keys are root keys of the
  shell, so help lists play/pause, seeking, preview sound and close with
  labels too; cells outside the shell take the theme's page colour; and the
  View refits through the Runtime instead of a global resize hook. CLI
  queries run through `etaf-process-run`. Requires ETAF 0.3.0 and ETAF UI
  0.2.0.

- Redesign the clip inspector as one framed panel: a title band, a scrolling
  body and a fixed footer with 上移／下移 and 删除. Controls stay one standard
  row with plain filled surfaces instead of bordered boxes, groups are
  separated by hairlines, and a short window scrolls the body while keeping
  the header and footer reachable. 取当前播放位置 fills a draft that 应用裁切
  saves, and speed or volume applies as soon as it is chosen.

- Give the action bar, preview, clip sequence and editing tools visible
  enclosing borders and separated title bars in both palettes. Empty projects
  no longer reserve a second empty clip panel, and resize gaps keep the app's
  background instead of exposing the surrounding Emacs theme.

- Start with a guided project card and persistent workflow actions. The same
  tool tabs remain visible in wide, compact and short windows; the usable
  minimum is now 80×28 cells. Project, clip, caption, target and task lists
  have page controls instead of silently clipping later entries.
- Video previews start paused and offer a seek bar. Finished exports can be
  revealed directly in the file manager from the export or task view.

### Fixed

- `?` opens help in a graphical frame again. Icons received deferred Theme
  tokens as face colours, which Emacs rejected (logging "Invalid face
  attribute" on every redisplay) and help's dimmed backdrop could not paint;
  icons now take concrete colours from their enclosing box and still follow
  the theme.

- Align the clip editor's labels, values and actions in separate trim, split
  and playback groups. Widen time fields for fractional-second source times;
  display volume as a percentage and separate deletion from edit actions.

- Source playback now seeks to the actual clip in point, and marks use the
  source clock without adding the in point a second time.
- Opening a project refreshes the library and selection; accepted edits and
  undo/redo refill the clip form instead of leaving stale trim values.
- Changing publication recipients, text or topic after reviewing a preview
  requires a new preview before sending.

### Added

- The video studio application: a project/library sidebar, a native
  `etaf-video` preview stage for a clip or the rendered cut, details and
  captions panes, a recording pane, a publish pane and a task pane, with
  wide, medium and narrow layouts over one ETAF Runtime.
- Non-destructive editing through the `video-project` CLI: import, trim,
  split, remove, reorder, speed, gain, caption add/update/delete, undo and
  redo, each carrying the revision the form was loaded with.
- Background preview (960 pixel) and screen (1920 pixel, CRF 18) renders
  with a status poll that adopts completed results, resumes interrupted
  exports and cancels only the open project's export; the jobs survive
  closing the application.
- macOS window/display recording with explicit target, audio mode and
  duration; the worker imports the saved file as a new clip.
- A two-step publish flow: silent preview of revision, target, visibility
  and text, then confirmation with the previewed revision; identical
  artifacts are never sent twice and unknown results are never retried.
- Public API: `etaf-video-studio-open`, `/close`, `/state`, `/refresh`, the
  project/import/edit/render/record/publish/selection/stage commands, plus
  `etaf-video-studio-root`, `etaf-video-studio-executable`,
  `etaf-video-studio-theme-mode`, `etaf-video-studio-poll-seconds` and
  `etaf-video-studio-request-timeout`.
