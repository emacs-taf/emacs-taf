# etaf-video-studio

Record, edit and publish software tutorials from one ETAF workbench: a
guided project start, a persistent action bar, a seekable native video preview,
ordered clip pages, explicit edit forms, background previews/exports, macOS
screen recording and a two-step publish flow. It is the text-application face of the
`video-project` skill and shares its projects with the CLI — no second
source of truth.

## Requirements

- Emacs 29.1 or newer.
- The `pi-skill` CLI with the `video-project` and `video-edit` skills, the
  `job-run` skill, and `ffmpeg` with libass for burned-in captions.
  `pi-skill video-project check` verifies the media side.
- macOS with the `macos-screencast` CLI for recording; other platforms can
  import, edit, export and publish.
- Provider checkouts: `etaf`, `etaf-ui`, `ebox` and `ecss`, either beside
  this repository (`../etaf` and so on) or two directories up (`../etaf`)
  as in the workspace checkout.

## Install and run

Add this repository root and the four provider roots to `load-path`, then:

```elisp
(require 'etaf-video-studio)
M-x etaf-video-studio-open
```

The studio opens `~/Movies/Video Projects` (or
`PI_SKILL_VIDEO_PROJECT_DIRECTORY`); set `etaf-video-studio-root` to pin a
different library, or call
`(etaf-video-studio-open "project-id" "/path/to/library")`.

## Make your first video

1. Enter a project title on the welcome card and choose **新建**.
2. Choose **导入素材**, or **录屏** and a window. Recording is silent unless
   you explicitly select audio; stopping imports the saved video.
3. Select a clip. Use the seek bar and play/pause, then edit its in/out
   seconds or split it; speed and volume apply as soon as you choose them.
   The **字幕** tab adds timed text. Changes save
   automatically; **撤销** restores the previous edit without touching sources.
4. Choose **预览成片** to render the edited cut, then **导出视频**. The
   **任务** and **导出** tabs show completion and **在文件夹中显示成片**.
5. Publishing is optional: preview the destination and text, then explicitly
   confirm. A public link is accessible to anyone who has it.

All tools remain in the same tabs on small windows. The minimum usable
viewport is 80 columns by 28 rows; lists have previous/next page controls.
This is a single-sequence tutorial editor, not a multi-track compositor;
captions are entered manually, not transcribed automatically.

Keys: `N` new project, `a` import, `SPC` play/pause, `v` preview, `e` export, `r` record pane, `R` start
or stop recording, `p` publish, `c` captions, `t` tasks, `i`/`o` mark in/out,
`s` split, `x` remove, `u`/`U` undo/redo, `T` theme, `g` refresh, `?` help,
`q` close. Closing the studio never stops a background task.

## Documentation

- [docs/manual.md](docs/manual.md) — workflows, keys, failure handling and a
  programmatic example.
- [docs/architecture.md](docs/architecture.md) — module responsibilities,
  data flow and invariants.
- The root entry's Commentary is the authoritative public interface list;
  `pi-skill video-project help` documents the shared CLI.

## Development

```sh
make check        # structure, byte compile, public acceptance, API boundary
make test         # only the public acceptance scenarios
make api-check    # root Commentary against the loaded definitions
make clean
```

Interface changes must keep the root Commentary, the manual and
`tests/acceptance.json` in step. GUI behavior changes need a real graphical
pass; `scripts/etaf-video-studio-gui-scenarios.el` drives the controls with
the shared window verifier against a generated clip and a temporary library.
