# ETAF Video Studio manual

`etaf-video-studio` is the text-application face of the `video-project`
skill. It begins with the skill's help: `pi-skill video-project help`.
Prerequisites are the `pi-skill` CLI with the `video-project` and
`video-edit` skills, `ffmpeg` with libass for burned-in captions, and the
`job-run` skill for background work. Recording additionally needs the
macOS `macos-screencast` CLI. Start the studio with `M-x
etaf-video-studio-open`, or
`(etaf-video-studio-open "video-1" "~/Movies/Video Projects")` to open one
project in a specific library. Every project change goes through the skill,
so the quality bar of `pi-skill video-project` applies unchanged:
non-destructive edits, background jobs that survive Emacs, and an explicit
confirmation before anything leaves the machine.

## Projects

The welcome card and 项目 tab list the session's library (default
`~/Movies/Video Projects`, or `PI_SKILL_VIDEO_PROJECT_DIRECTORY`). Click a
row to open it. Enter a title and press 新建 (or RET) to create and open a
project; `N` offers the same command through the minibuffer. Lists show five
entries per page with 上一页 / 下一页 controls. Paging does not change selection.
Opening a project resets its pages and loads its first clip when available. 刷新 ( `g` )
reloads both the list and the open project. A project shows its revision
and total duration in the header, and the status menu reports the
revision through the CLI parser, so the window and the skill always agree.

The application never reads or writes `project.json`; closing the studio
neither stops a running export/recording/publish nor removes a project.
Reopening re-reads the library.

## Recording

Open 录屏 (`r`); the first visit automatically lists current macOS windows
and displays. 刷新 reloads that inventory. Targets come from the CLI's inventory at that
moment; a stale ID is rejected by the skill. Select a row, choose the audio
mode (`none` by default; `system`, `microphone` or both) and the maximum
duration (1–7200 seconds), then 开始录制 (`R`). 停止录制 sends the stop
request; the worker saves the file and imports it as a new clip at the end
of the timeline. Recording failures leave the partial source file alone.

## Importing

`a` (or the 导入 button) asks for one video file and imports it as a new
clip. Repeat the command to add more. The CLI probes each file's duration;
an unreadable file is rejected before the project changes.

## Editing

The ordered clip list is the timeline; this editor does not offer overlapping
tracks, transitions, automatic transcription or automatic silence removal.
Selecting a row opens 剪辑, fills its form and loads a paused source preview
at the clip's actual in point. The seek bar supports pointer positioning and
one-second Left/Right steps; `SPC` plays or pauses, and `i`, `o` and `s` edit
at the absolute source position. Selecting a clip also reveals its list page.
Accepted clip edits and undo/redo refresh the form from the saved result;
background polls leave unfinished drafts alone. The editor separates trimming
from splitting. Every row aligns its label, value and action; the time fields
reserve room for millisecond values such as `60.183` without splitting the
number across lines. Volume is displayed as a percentage rather than a raw gain.

The 剪辑 pane is one framed panel: a title band carrying the clip position, a
scrolling body with the edit groups and a fixed footer holding 上移／下移 and
删除. Controls keep one standard row in both palettes, so a short window
scrolls the body instead of compressing labels, and refocusing a control
reveals it. 取当前播放位置 fills the corresponding time field as a draft for
further editing; 应用裁切 saves both fields in one revision.

| Action | Form | Key |
| --- | --- | --- |
| Trim to source in/out | 入点／出点 → 应用裁切 | `i` / `o` set from the stage and save at once |
| Split | 位置 → 分割 | `s` at the stage position |
| Move | 上移 / 下移 | `,` / `.` |
| Remove | 删除 | `x` (undo restores it) |
| Speed | 速度（选择后立即生效） | — |
| Volume | 音量百分比（选择后立即生效） | — |
| Undo / redo | 撤销 / 重做 | `u` / `U` |

Source times are seconds in the *material*; captions are positioned on the
*finished* timeline. The CLI remaps captions when clips are trimmed, split,
reordered, sped up or removed, and the skill's history (100 snapshots)
covers every edit. An operation reports `conflict` when another entry
changed the project since the form was loaded; 刷新 (`g`) re-reads it
before retrying. Nothing is written until the operation is applied.

Captions live in the 字幕 pane: select a row to load it into the form, edit
the start/end seconds and text, then 更新说明. RET in the text field
submits the same update. `删除` removes the selected caption and 新建
clears the form for a new one.

## Preview and playback

`v` starts a low-resolution (960 pixel) preview render of the current
revision in the background. While it runs, the task pane shows its status;
when it completes, the stage switches to the rendered cut and 成片预览 /
选中片段 switches between the cut and the selected clip's material. The
preview is always the same edit decision list as the export, so a cut that
plays here is the cut that renders.

The stage starts paused and silent; `m` toggles sound. Loading a source never
starts unexpected playback. The bar seeks within the displayed source; the
source preview is the original recording, whereas the rendered preview
includes cuts, speed, gain and captions. `SPC` play/pause,
`f`/`b` seek five seconds, and the footer clock follows the native video
session. Editing the project makes the rendered preview stale: it is
replaced by the next completed preview of the new revision instead of
pretending to be the new cut. The stage falls back to a density-ramp canvas
on terminal frames.

## Exporting

`e` starts a background screen-profile export (1920 pixel, CRF 18) of the
current revision. The task pane (`t`) lists tasks with status and output;
续跑导出 resumes an interrupted export and reuses validated segments, and
取消导出 stops only this project's export. Closing the studio does not
stop these jobs — they belong to `job-run`. A failed export keeps its task
and message, and 续跑导出 retries from the finished segments. Newest tasks
appear first. A completed export of the current revision exposes
在文件夹中显示成片 in both 任务 and 导出: it reveals the file in Finder on
macOS, or opens its containing directory in Dired elsewhere. This never uploads
anything. Editing makes the previous export ineligible for current publication.

## Publishing

The 发布 pane previews before it sends. Choose the target (`Telegram` or
公开链接), fill the chat ID for Telegram, and optionally the text and
topic; 预览发布 asks the CLI for a preview object naming the revision,
target, visibility and text. Nothing is sent. Review it, then 确认发布
sends the same request with the previewed revision and `--yes`; a project
that changed in between requires a new preview. Changing the recipient,
text, target or topic also requires a new preview; confirmation cannot silently
send different content. An identical artifact and text is never sent again. A publish whose result is unknown is reported
as such and must be checked against the target — the application never
retries it automatically.

## Layout and keys

The framed action bar always exposes import, recording, undo/redo, preview and
export. Preview, clip sequence and editing tools each have a visible enclosing
border and a separated title bar in both themes. The same eight tabs remain
visible at every supported size. With at least 1100 logical pixels and 34
viewport rows, the preview sits beside the editor; from 40 rows a nonempty
ordered clip list also appears in its own panel below it. Smaller or shorter
windows show one tool at a time. 项目 always opens the project card instead
of reserving an empty sidebar, and 任务 occupies space only when selected.
The minimum usable viewport is 80 columns by 28 rows; below that the layout
keeps its structure and the window clips deliberately. The footer always
carries the key hints; `?` opens ETAF's full help with every studio key and
its label, `M-g` jumps between regions and TAB moves focus. The View refits
when its window settles at a new size, and the area outside the shell keeps
the studio's page colour in both themes.

## State and programmatic use

`etaf-video-studio-state` returns a detached plist of the open buffer;
`etaf-video-studio-open`, `etaf-video-studio-open-project`,
`etaf-video-studio-create-project`, `etaf-video-studio-import-files` and
the command functions cover the documented workflows, and
`etaf-video-studio-close` (or killing the buffer) releases timers and
in-flight queries. The root
entry Commentary is the authoritative interface list.

```elisp
(let* ((root (make-temp-file "library-" t))
       (etaf-video-studio-root root)
       (buffer (etaf-video-studio-open)))
  (etaf-video-studio-create-project "第一个教程")
  ;; Wait for the CLI round trips, then inspect the public state.
  (plist-get (etaf-video-studio-state) :project))
```
