# etaf-export Manual

`etaf-export` registers as an `on-command` extension inside `etaf-ext` requiring `(keys popup notify storage)`. It incurs zero render or layout cost until an export command or preview workspace is invoked.

## Configuration

Customize the default layout, color strategy, page numbers, margin, font stack and `rsvg-convert` executable before or after loading `etaf-export`:

```elisp
(require 'etaf-ext)
(require 'etaf-export)
(setq etaf-export-default-page-mode 'a4
      etaf-export-default-theme 'current
      etaf-export-page-numbers t
      etaf-export-margin 28)
(etaf-ext-mode 1)
```

## Interactive Workflows

`etaf-export` exposes three core interactive commands both via `M-x` and under `etaf-ext`'s unified extension prefix (`C-c C-e x`):

- `C-c C-e x x` (`M-x etaf-export`): open the live vector Export Preview workspace for the current mounted ETAF page. The workspace shows a real-time vector preview of each page alongside controls for pagination (`a4`, `letter`, `single`), color theme (`current`, `light`), margin presets (`16`, `28`, `40` pt) and page numbers, persisting your last interactive choices via `etaf-ext` storage. Inside the workspace, use `n`/`p` (or `[`/`]`) to flip pages, `z` to toggle fit-page/fit-width zoom, `m`/`t`/`b`/`#` to change options, `e` to export PDF, `s` to export SVG, `g` to recapture the live source buffer and `q` or `Esc` to close and return.
- `C-c C-e x p` (`M-x etaf-export-pdf`): prompt for a `.pdf` path and export the active page using the configured defaults.
- `C-c C-e x s` (`M-x etaf-export-svg`): prompt for a `.svg` path and export standalone vector SVG page(s).

## Programmatic API and Personal Presets

`etaf-export-pdf` and `etaf-export-svg` serve both interactive use and batch scripting. Pass an explicit path for silent programmatic export, or pass `nil` as `output-file` inside your own interactive wrapper to prompt for a destination path while pinning preferred options:

```elisp
(require 'etaf)
(require 'etaf-export)

;; Batch export an already-mounted runtime RT to an A4 light-theme PDF:
(etaf-export-pdf "/tmp/report.pdf"
                 :runtime rt
                 :page-mode 'a4
                 :theme 'light
                 :page-numbers t)

;; Export a single continuous vector SVG:
(etaf-export-svg "/tmp/report.svg"
                 :runtime rt
                 :page-mode 'single)

;; Define a personal interactive preset (prompts for output file on interactive Emacs):
(defun my/etaf-export-light-pdf ()
  (interactive)
  (etaf-export-pdf nil :page-mode 'a4 :theme 'light))
```

Both functions validate `output-file`, `page-mode` (`a4`, `letter`, `single`) and `theme` (`current`, `light`), signalling `etaf-export-error` on invalid arguments, missing runtime or missing `rsvg-convert`.

## Diagnostics and Recovery

Run `(etaf-export-doctor)` to inspect whether `rsvg-convert` is available on `exec-path` or standard Homebrew/system paths. If `rsvg-convert` is missing, `etaf-export-pdf` signals `etaf-export-error` with the install command (`brew install librsvg` on macOS, `apt install librsvg2-bin` on Linux), while live preview (`etaf-export`) and `etaf-export-svg` remain fully functional.
