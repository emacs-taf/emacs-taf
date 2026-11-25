# etaf-export Manual

`etaf-export` registers as an `on-command` extension inside `etaf-ext` requiring `(keys popup notify)`. It incurs zero render or layout cost until an export command or popup is invoked.

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

When `etaf-ext-mode` is active on any mounted ETAF buffer, `etaf-export` contributes five commands to the extension key layer:

- `C-c C-e x p` (`export-pdf`): prompt for a `.pdf` path and export using `etaf-export-default-page-mode` and `etaf-export-default-theme`.
- `C-c C-e x l` (`export-long`): prompt for a `.pdf` path and export as one continuous tall page (`page-mode = single`).
- `C-c C-e x L` (`export-light`): prompt for a `.pdf` path and export in `a4` mode with `theme = light`, remapping dark pages onto white paper without modifying the open Emacs buffer.
- `C-c C-e x s` (`export-svg`): export standalone vector SVG page(s).
- `C-c C-e x x` (`panel` / `M-x etaf-export-popup`): open a floating popup to toggle page mode, theme and page numbers before exporting.

## Programmatic API

Use `etaf-export-pdf` and `etaf-export-svg` from batch scripts, tests or application workflows:

```elisp
(require 'etaf)
(require 'etaf-export)

;; Export an already-mounted runtime RT to an A4 light-theme PDF:
(etaf-export-pdf "/tmp/report.pdf"
                 :runtime rt
                 :page-mode 'a4
                 :theme 'light
                 :page-numbers t)

;; Export a single continuous vector SVG:
(etaf-export-svg "/tmp/report.svg"
                 :runtime rt
                 :page-mode 'single)
```

Both functions validate `output-file`, `page-mode` (`a4`, `letter`, `single`) and `theme` (`current`, `light`), signalling `etaf-export-error` on invalid arguments, missing runtime or missing `rsvg-convert`.

## Diagnostics and Recovery

Run `(etaf-export-doctor)` to inspect whether `rsvg-convert` is available on `exec-path` or standard Homebrew/system paths. If `rsvg-convert` is missing, `etaf-export-pdf` signals `etaf-export-error` with the install command (`brew install librsvg` on macOS, `apt install librsvg2-bin` on Linux), while `etaf-export-svg` remains fully functional.
