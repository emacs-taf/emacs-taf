# ETAF Video Studio architecture

## Responsibilities

`etaf-video-studio` is an application. It owns the buffer, the layout, the
selection, the edit forms and the status timers. The `video-project` skill
owns the project store, the edit history, the render/record/publish tasks
and every background process, and ETAF's native `etaf-video` Component owns
decoding and playback. No framework mechanism and no project rule is
re-implemented here.

| Module | Owns |
| --- | --- |
| `etaf-video-studio-app` | the application lifecycle over `etaf-app-open`, the root keys, timers, public commands and the CLI request lifecycle |
| `etaf-video-studio-views` | the shell, panes and rows as pure projections of the snapshot and the draft refs |
| `etaf-video-studio-model` | the application record, the snapshot ref, selection and stage reconciliation, request/pending bookkeeping |
| `etaf-video-studio-backend` | one bounded asynchronous `pi-skill` invocation per request through `etaf-process-run`, JSON parsing and the CLI error contract |
| `etaf-video-studio-theme` | the dark/light palettes and their ETAF UI token projection, derived with `etaf-ui-theme-tokens` |

The root entry re-exports the supported subset; everything unlisted is
internal.

## Data flow

1. `etaf-video-studio-open` creates the record and opens the shell as an
   ETAF application: the buffer's surface follows the theme's page colour,
   the shell's root keys carry their help labels, and the Runtime refits the
   View after each settled window change. It then starts a 0.5 s stage clock
   plus a 2 s status poll. The first refresh lists the library; opening a
   project fetches its public `status` object.
2. Every command builds one CLI argument list and passes it to
   `etaf-video-studio--app-request`, which counts the in-flight query,
   publishes a busy snapshot and calls the backend. The backend runs
   `pi-skill … --json` through `etaf-process-run`, which collects stdout and
   stderr and settles once, and delivers a parsed plist to the application
   buffer. A missing executable is an immediate `deps` result; a request past
   `etaf-video-studio-request-timeout` is stopped and reported. The command
   loop is never blocked.
3. A successful project answer is adopted through
   `etaf-video-studio--app-adopt-project`: the public project replaces the
   record's copy, selections are clamped into the refreshed lists, a
   publish confirmation for another revision is dropped, and the stage
   follows the current revision's completed preview unless the user is
   watching a clip. Accepted edits also refill the selected clip form; polls
   do not. Opening another project clears the old stage before adopting its
   replacement. A changed stage file is probed once for its size with
   `video-edit probe`; the result only sizes the canvas.
4. Commands publish one snapshot; the shell subscribes only to project
   presence and the selected tool. Each mounted region derives an equal-tested
   projection of the fields it displays, so selecting a clip does not rebuild
   navigation, project controls or unrelated forms. Draft refs remain separate.
   The status poll compares project revision, updated time, task statuses and
   receipts before publishing. Clock Hosts and the seek bar's retained fill
   update independently; a poll never overwrites what a person typed.
5. Background work leaves the application: `render`, `record start` and
   `publish` return a task immediately, and the worker runs in a `job-run`
   process group. A completed preview render becomes `:preview`; a
   completed recording is imported by the worker as a new clip at the end
   of the timeline.
6. `etaf-video-studio-close`, or killing the buffer, runs the application's
   single close function: it cancels the timers and the in-flight CLI
   queries, and the Runtime is unmounted. It never stops a task.

## Invariants

- The CLI is the only writer. The application never reads or writes a
  project file, never rescales a timeline itself and never guesses a
  revision.
- Every mutation carries the revision the form was loaded with. A
  `conflict` answer is reported and the project is re-read; no write is
  retried blindly.
- Publish has two distinct steps: a preview names revision, target, visibility
  and text. It retains the reviewed request arguments; confirmation rejects
  changed arguments as well as changed revisions before adding `--yes`.
  An `unknown` result requires human verification, never automatic retry.
- The stage never mounts a missing file, so a stale preview cannot start a
  decoder. A rendered preview is tied to its revision: editing the project
  clears or replaces it instead of presenting an old cut as the new one.
- Views are side-effect free; requests come from commands and callbacks,
  never from a render.
- Hidden panes do not exist in the layout. Compact or short windows mount
  one tool; sufficiently wide and tall windows keep the preview beside it.
  Navigation is outside the content region's height budget and never shrinks
  away. List paging is transient application state; the CLI remains the only
  owner of the full list and its ordering.
- The source preview is paused on mount. Its initial seek and edit marks use
  the same absolute source clock, never an added display-only offset. The
  seek bar reads a dedicated ref through the catalog's retained fill binding.

## Failure semantics

| Answer | Application behavior |
| --- | --- |
| `usage` | the offending form stays loaded and the CLI message is shown |
| `deps` | the status line names the missing executable; no retry loop |
| `conflict` | the message asks for a refresh; `g` re-reads the project |
| `blocked` | the skill's reason and hint are shown; `unknown` publishes are never resent automatically |
| `timeout` | the query ends; the background task keeps running and the poll still adopts its result |
| `interrupted` | the task row stays; 续跑导出 resumes the export |

## Layout and sizing

Every major work area has a continuous visible frame, a separated title bar
and consistent inset spacing, using the catalog's Panel and the theme's
frame colour. Near-identical fills or whitespace alone are not region
boundaries. The canvas includes an explicit background plane so gaps retain
the application palette rather than exposing the user's frame background.

The shell budgets eight rows for its title, framed action bar and persistent
tabs, then four for a padded status/key footer. The remaining region shows the
welcome card or the selected tool. At 1100 logical pixels and 34 viewport
rows it splits into a framed preview and a 64-cell inspector; from 40 rows,
a nonempty clip sequence has its own eleven-row panel below the preview.
Empty projects show only the preview's onboarding, not a second empty list. Width alone never
forces an unusable split in a short window. Lists page five rows, keeping
forms and page controls reachable instead of clipping long collections.

The clip inspector is one framed panel with a rounded outline: a three-row
title band, a scrolling body and a fixed footer holding the ordering and
delete actions. Groups inside the body are separated by hairline rules rather
than nested frames, and every control keeps one standard row with a plain
filled surface, so a short window scrolls the body instead of compressing
labels; focusing a control scrolls it into view. Trim and split are separate
groups with fourteen-cell value fields whose width includes input padding, so
fractional source times remain intact. 取当前播放位置 fills a time field as a
draft and 应用裁切 saves both fields; choosing a speed or volume option
applies that edit at once and reports its result in the status line.
The video canvas derives its aspect from the source and its size from the
remaining row and column budget. The supported minimum is 80×28; smaller
viewports retain that structure with deliberate clipping.

## Testing

Public behavior is covered by `tests/etaf-video-studio-tests.el` with a
fixture CLI that records its arguments and answers canned JSON, so the
whole command surface — open/create/import/edit/history/render/record/
publish/state — runs offline. GUI acceptance mounts the real skill against
a real generated clip; see the repository README for the commands.
