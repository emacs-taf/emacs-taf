;;; etaf-video-studio.el --- Record, edit and publish tutorial videos -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Author: ETAF contributors
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.1") (etaf "0.3.0") (etaf-ui "0.2.0"))
;; Keywords: multimedia, tools, ui
;; URL: https://github.com/emacs-taf/etaf-video-studio

;;; Commentary:

;; Public API
;;
;; Load this package with (require 'etaf-video-studio) after adding this
;; repository root and the ETAF, ETAF UI, Ebox and ECSS roots to
;; `load-path'.  The studio is the text-application face of the
;; `video-project' skill: it records a window or screen, imports existing
;; media, edits clips and captions non-destructively, renders previews and
;; exports in the background, and publishes a finished export to Telegram or
;; a public link after an explicit confirmation.  The skill owns the project
;; library and every background job; the application never reads or writes a
;; project file itself.  The CLI (`pi-skill video-project') must be
;; installed and `ffmpeg' must provide libass for burned-in captions.
;;
;; A session is one ETAF application buffer (`*Video Studio*') showing one
;; project.  Its keys belong to the shell, so `?' lists every one with its
;; label; the canvas surface follows the theme and the View refits when its
;; window settles at a new size.  The shell starts with project creation and recent projects.  Persistent tools
;; and named tabs lead to the clip sequence, native preview with a seek bar,
;; editing forms, captions, recording, exports and tasks.  Wide, tall windows
;; put the preview and sequence beside the editor; compact windows show one
;; tool at a time with the same navigation.  Lists page five entries at a
;; time; the minimum viewport is 80 by 28 cells.  Every editing
;; form keeps its draft locally and only sends the operation when its button
;; (or key) is used; a slower status poll updates the project without losing
;; a draft.
;;
;; Only the interfaces listed below are supported for use by other packages.
;; All unlisted symbols and implementation features are internal, including
;; names without a double hyphen.  Do not require files below lisp/ from
;; consumers.  This Commentary is the authoritative export list;
;; implementations and precise docstrings remain beside their definitions,
;; and the manual contains workflows.
;;
;; Function: etaf-video-studio-open (&optional project root)
;;;###autoload (autoload 'etaf-video-studio-open "etaf-video-studio" nil t)
;; Mount the studio in its own buffer and return that buffer.
;; PROJECT optionally names the project to open (an id or a directory);
;; ROOT pins the project library for the session, defaulting to
;; `etaf-video-studio-root' and then to the CLI default
;; (`~/Movies/Video Projects' or `PI_SKILL_VIDEO_PROJECT_DIRECTORY').  An
;; already open studio is closed first; a missing skill reports `deps' in
;; the status line instead of signaling.
;;
;; Function: etaf-video-studio-close ()
;;;###autoload (autoload 'etaf-video-studio-close "etaf-video-studio" nil t)
;; Close the studio in the current buffer and return t.
;; The status timers and in-flight CLI queries are cancelled and the ETAF
;; Runtime is unmounted; killing the buffer releases the same resources.
;; Background jobs (render, record, publish) belong to `job-run' and keep
;; running.  Outside a studio buffer it signals `user-error'.
;;
;; Function: etaf-video-studio-state ()
;;;###autoload (autoload 'etaf-video-studio-state "etaf-video-studio" nil t)
;; Return the current studio's state as a detached plist.
;; Keys are `:buffer', `:root', `:projects' (count), `:project' (id, title,
;; revision, directory, undo, redo or nil), `:pane', `:pages' (list-name to
;; zero-based-page alist), `:clip-index',
;; `:caption-index', `:task-index', `:clips' (count), `:captions' (count),
;; `:tasks' (id, kind, status, revision, profile and output per task),
;; `:record-targets' (count), `:record-target-index', `:record' (the active
;; recording task or nil), `:preview' (output and revision of the completed
;; preview), `:publish-preview' (revision, target, chat, text and visibility
;; of the last preview, or nil), `:stage' (file, kind, base and absolute
;; playback position in seconds),
;; `:stage-playing', `:pending' (in-flight CLI queries) and `:message'.  It
;; signals `user-error' outside a studio buffer.
;;
;; Function: etaf-video-studio-refresh ()
;;;###autoload (autoload 'etaf-video-studio-refresh "etaf-video-studio" nil t)
;; Reload the project list and the open project's status from the CLI.
;;
;; Function: etaf-video-studio-open-project (project)
;;;###autoload (autoload 'etaf-video-studio-open-project "etaf-video-studio" nil t)
;; Open PROJECT in the studio.
;; PROJECT is a list row from the project list, an id or a directory.  The
;; selection, caption form and any stale publish preview are reset; a
;; completed preview of the opened revision becomes the stage source.
;;
;; Function: etaf-video-studio-create-project (title)
;;;###autoload (autoload 'etaf-video-studio-create-project "etaf-video-studio" nil t)
;; Create a project titled TITLE in the session's library and open it.
;; The CLI confirms the write and chooses the directory; an empty TITLE
;; signals `user-error'.
;;
;; Function: etaf-video-studio-import-files (files)
;;;###autoload (autoload 'etaf-video-studio-import-files "etaf-video-studio" nil t)
;; Import FILES as new clips at the end of the open project's timeline.
;; FILES is a nonempty list of local media file names; the CLI probes each
;; clip's duration.  Interactive use reads one file name.
;;
;; Function: etaf-video-studio-apply-trim ()
;;;###autoload (autoload 'etaf-video-studio-apply-trim "etaf-video-studio" nil t)
;; Trim the selected clip to the form's source in and out points (seconds).
;; The in point must be smaller than the out point; captions follow the
;; edit through the CLI's timeline remapping.
;;
;; Function: etaf-video-studio-apply-split ()
;;;###autoload (autoload 'etaf-video-studio-apply-split "etaf-video-studio" nil t)
;; Split the selected clip at the form's source time (seconds).
;;
;; Function: etaf-video-studio-apply-speed ()
;;;###autoload (autoload 'etaf-video-studio-apply-speed "etaf-video-studio" nil t)
;; Apply the speed select to the selected clip.
;;
;; Function: etaf-video-studio-apply-gain ()
;;;###autoload (autoload 'etaf-video-studio-apply-gain "etaf-video-studio" nil t)
;; Apply the gain select to the selected clip.
;;
;; Function: etaf-video-studio-mark-in ()
;;;###autoload (autoload 'etaf-video-studio-mark-in "etaf-video-studio" nil t)
;; Set the selected clip's source in point to the stage's current position.
;; Only a clip-source preview carries a source position; a rendered preview
;; signals `user-error'.
;;
;; Function: etaf-video-studio-mark-out ()
;;;###autoload (autoload 'etaf-video-studio-mark-out "etaf-video-studio" nil t)
;; Set the selected clip's source out point to the stage's current position.
;;
;; Function: etaf-video-studio-split-at-stage ()
;;;###autoload (autoload 'etaf-video-studio-split-at-stage "etaf-video-studio" nil t)
;; Split the selected clip at the stage's current source position.
;;
;; Function: etaf-video-studio-move-clip-up ()
;;;###autoload (autoload 'etaf-video-studio-move-clip-up "etaf-video-studio" nil t)
;; Move the selected clip one position earlier in the timeline.
;;
;; Function: etaf-video-studio-move-clip-down ()
;;;###autoload (autoload 'etaf-video-studio-move-clip-down "etaf-video-studio" nil t)
;; Move the selected clip one position later in the timeline.
;;
;; Function: etaf-video-studio-remove-selected-clip ()
;;;###autoload (autoload 'etaf-video-studio-remove-selected-clip "etaf-video-studio" nil t)
;; Remove the selected clip; undo restores it.
;;
;; Function: etaf-video-studio-undo ()
;;;###autoload (autoload 'etaf-video-studio-undo "etaf-video-studio" nil t)
;; Step the project history back one edit.
;;
;; Function: etaf-video-studio-redo ()
;;;###autoload (autoload 'etaf-video-studio-redo "etaf-video-studio" nil t)
;; Step the project history forward one edit.
;;
;; Function: etaf-video-studio-render-preview ()
;;;###autoload (autoload 'etaf-video-studio-render-preview "etaf-video-studio" nil t)
;; Start a background low-resolution (960 pixel) preview render.
;; The task returns immediately and the status poll adopts it when it
;; completes, so the stage can play the cut while the project is still
;; editable; editing the project marks the preview stale.
;;
;; Function: etaf-video-studio-render-screen ()
;;;###autoload (autoload 'etaf-video-studio-render-screen "etaf-video-studio" nil t)
;; Start a background screen-profile export (1920 pixel, CRF 18).
;; Publishing requires a completed screen export of the current revision.
;;
;; Function: etaf-video-studio-show-export ()
;;;###autoload (autoload 'etaf-video-studio-show-export "etaf-video-studio" nil t)
;; Reveal the current revision's completed screen export in Finder on macOS,
;; or Dired elsewhere, and return its path.  Missing or stale exports signal
;; `user-error'; nothing is uploaded and the original files stay untouched.
;;
;; Function: etaf-video-studio-page-list (kind delta)
;;;###autoload (autoload 'etaf-video-studio-page-list "etaf-video-studio" nil nil)
;; Move KIND's visible list by integer DELTA pages without changing selection.
;; KIND is projects, clips, captions, record or tasks.  Pages clamp at either
;; end; selecting a clip reveals its page.  Invalid arguments signal
;; `user-error'.  Page state is per buffer and resets when a project opens.
;;
;; Function: etaf-video-studio-task-retry ()
;;;###autoload (autoload 'etaf-video-studio-task-retry "etaf-video-studio" nil t)
;; Resume an interrupted export; validated segments are reused.
;;
;; Function: etaf-video-studio-cancel-render ()
;;;###autoload (autoload 'etaf-video-studio-cancel-render "etaf-video-studio" nil t)
;; Cancel the running export of the open project.
;;
;; Function: etaf-video-studio-refresh-targets ()
;;;###autoload (autoload 'etaf-video-studio-refresh-targets "etaf-video-studio" nil t)
;; Reload the recording target inventory (macOS windows and displays).
;;
;; Function: etaf-video-studio-record-start ()
;;;###autoload (autoload 'etaf-video-studio-record-start "etaf-video-studio" nil t)
;; Start recording the selected target with the form's audio and duration.
;; Audio defaults to silent; the duration must be 1 to 7200 seconds.  The
;; worker imports the recording as a new clip when it stops.
;;
;; Function: etaf-video-studio-record-stop ()
;;;###autoload (autoload 'etaf-video-studio-record-stop "etaf-video-studio" nil t)
;; Stop the running recording gracefully.
;;
;; Function: etaf-video-studio-toggle-record ()
;;;###autoload (autoload 'etaf-video-studio-toggle-record "etaf-video-studio" nil t)
;; Start the selected target, or stop the running recording.
;;
;; Function: etaf-video-studio-publish-preview ()
;;;###autoload (autoload 'etaf-video-studio-publish-preview "etaf-video-studio" nil t)
;; Ask the CLI for the publish preview of the current export.
;; The preview names the revision, target, visibility and text; nothing is
;; sent.  Telegram needs a chat; `share' publishes a public link.
;;
;; Function: etaf-video-studio-publish-confirm ()
;;;###autoload (autoload 'etaf-video-studio-publish-confirm "etaf-video-studio" nil t)
;; Send the previewed publish with its revision as confirmation.
;; A changed revision, target, text or topic signals `user-error' and must
;; be previewed again; an identical artifact and text is never sent twice.
;;
;; Function: etaf-video-studio-publish-reset ()
;;;###autoload (autoload 'etaf-video-studio-publish-reset "etaf-video-studio" nil t)
;; Discard the current publish preview.
;;
;; Function: etaf-video-studio-add-caption ()
;;;###autoload (autoload 'etaf-video-studio-add-caption "etaf-video-studio" nil t)
;; Add a caption from the form, or update the caption being edited.
;; Start and end are final-timeline seconds; the start must be smaller than
;; the end and the text nonempty.
;;
;; Function: etaf-video-studio-delete-caption ()
;;;###autoload (autoload 'etaf-video-studio-delete-caption "etaf-video-studio" nil t)
;; Delete the selected caption.
;;
;; Function: etaf-video-studio-clear-caption-form ()
;;;###autoload (autoload 'etaf-video-studio-clear-caption-form "etaf-video-studio" nil t)
;; Clear the caption form and leave caption edit mode.
;;
;; Function: etaf-video-studio-stage-selected-clip ()
;;;###autoload (autoload 'etaf-video-studio-stage-selected-clip "etaf-video-studio" nil t)
;; Show the selected clip's source file in the stage, seeked to its in point.
;;
;; Function: etaf-video-studio-stage-preview-output ()
;;;###autoload (autoload 'etaf-video-studio-stage-preview-output "etaf-video-studio" nil t)
;; Show the completed preview render of the current revision in the stage.
;;
;; Function: etaf-video-studio-toggle-playback ()
;;;###autoload (autoload 'etaf-video-studio-toggle-playback "etaf-video-studio" nil t)
;; Toggle the stage video; with no stage, show the preview or the clip.
;;
;; Function: etaf-video-studio-toggle-stage-audio ()
;;;###autoload (autoload 'etaf-video-studio-toggle-stage-audio "etaf-video-studio" nil t)
;; Toggle the preview stage's sound (silent by default).
;;
;; Function: etaf-video-studio-seek-to (seconds)
;;;###autoload (autoload 'etaf-video-studio-seek-to "etaf-video-studio" nil t)
;; Seek the displayed source to nonnegative absolute SECONDS, clamped to its
;; duration, and return the requested position.  A paused video stays paused;
;; playback and editing positions use the same source clock.  With no mounted
;; video or invalid seconds, signal `user-error'.
;;
;; Function: etaf-video-studio-seek-forward ()
;;;###autoload (autoload 'etaf-video-studio-seek-forward "etaf-video-studio" nil t)
;; Seek the stage video forward five seconds.
;;
;; Function: etaf-video-studio-seek-backward ()
;;;###autoload (autoload 'etaf-video-studio-seek-backward "etaf-video-studio" nil t)
;; Seek the stage video back five seconds.
;;
;; Function: etaf-video-studio-select-pane (pane)
;;;###autoload (autoload 'etaf-video-studio-select-pane "etaf-video-studio" nil t)
;; Switch the details area to PANE, one of `projects', `clips', `preview',
;; `properties', `captions', `record', `publish' or `tasks'.
;;
;; Function: etaf-video-studio-select-clip (index)
;;;###autoload (autoload 'etaf-video-studio-select-clip "etaf-video-studio" nil t)
;; Select clip INDEX, prefill the edit form and show the clip in the stage.
;;
;; Function: etaf-video-studio-select-caption (index)
;;;###autoload (autoload 'etaf-video-studio-select-caption "etaf-video-studio" nil t)
;; Select caption INDEX and load it into the form.
;;
;; Function: etaf-video-studio-select-target (index)
;;;###autoload (autoload 'etaf-video-studio-select-target "etaf-video-studio" nil t)
;; Select recording target INDEX.
;;
;; Function: etaf-video-studio-select-task (index)
;;;###autoload (autoload 'etaf-video-studio-select-task "etaf-video-studio" nil t)
;; Select task INDEX.
;;
;; Function: etaf-video-studio-show-record ()
;;;###autoload (autoload 'etaf-video-studio-show-record "etaf-video-studio" nil t)
;; Show the recording pane.
;;
;; Function: etaf-video-studio-show-captions ()
;;;###autoload (autoload 'etaf-video-studio-show-captions "etaf-video-studio" nil t)
;; Show the captions pane.
;;
;; Function: etaf-video-studio-show-publish ()
;;;###autoload (autoload 'etaf-video-studio-show-publish "etaf-video-studio" nil t)
;; Show the publish pane.
;;
;; Function: etaf-video-studio-show-tasks ()
;;;###autoload (autoload 'etaf-video-studio-show-tasks "etaf-video-studio" nil t)
;; Show the tasks pane.
;;
;; Function: etaf-video-studio-toggle-theme ()
;;;###autoload (autoload 'etaf-video-studio-toggle-theme "etaf-video-studio" nil t)
;; Switch between the dark and light palette and republish the shell.
;;
;; Variable: etaf-video-studio-root
;; Project library the session pins for every CLI call.
;; Nil uses the CLI's own root (`~/Movies/Video Projects' or
;; `PI_SKILL_VIDEO_PROJECT_DIRECTORY'); set it to keep a session inside a
;; different library, such as a test checkout.
;;
;; Variable: etaf-video-studio-executable
;; Program providing the `video-project' and `video-edit' commands.
;; Defaults to `pi-skill'; tests point it at a fake CLI.
;;
;; Variable: etaf-video-studio-theme-mode
;; Appearance of the application: `dark' (default) or `light'.
;;
;; Variable: etaf-video-studio-poll-seconds
;; Seconds between status polls of a displayed project.
;;
;; Variable: etaf-video-studio-request-timeout
;; Seconds after which one CLI query is killed and reported.

;;; Code:

;;;###autoload
(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name "lisp"
                                 (file-name-directory
                                  (or load-file-name
                                      (bound-and-true-p byte-compile-current-file)
                                      buffer-file-name)))))

(require 'etaf-video-studio-app)

(provide 'etaf-video-studio)
;;; etaf-video-studio.el ends here
