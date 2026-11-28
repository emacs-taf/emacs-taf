# etaf-screensaver

Idle generative screensavers for Emacs, built on [ETAF](https://github.com/emacs-taf/etaf). After an idle interval, pure-Elisp animation fills the current frame's editing area; any key press, mouse movement, completed click or wheel event dismisses it and restores the prior window configuration without replaying input. There are no in-screen controls, status bars or external processes.

This is a visual screensaver, **not a security lock**. Dismissal releases its animation timer, transient wake map, hooks and buffer, and restores mouse tracking and `gc-cons-threshold`. Automatic mode retains only one idle timer and one post-command rearming hook; disabling it releases those too.

## Requirements and setup

Emacs 29.1 or later. Install from the ETAF package archive (`https://etaf.top/packages/`) with `M-x etaf-install` and select `etaf-screensaver`, or clone [`emacs-taf/etaf`](https://github.com/emacs-taf/etaf) and add `etaf/packages/{ecss,ebox,etaf}` and this package root to `load-path`:

```elisp
(require 'etaf-screensaver)
(setq etaf-screensaver-idle-delay 300
      etaf-screensaver-order 'shuffle
      etaf-screensaver-playlist
      '(poems
        (matrix :speed 12 :duration 20)
        (donut :speed 8 :detail fine)
        snow
        clock))
(etaf-screensaver-mode 1)
```

## Commands

- `M-x etaf-screensaver-open`: start the configured playlist (`C-u` prompts for a single scene).
- `M-x etaf-screensaver-preview`: choose any registered scene with completion and preview it without changing playback state.
- `M-x etaf-screensaver-mode`: toggle automatic idle presentation.
- `M-x etaf-screensaver-stop`: explicit, idempotent dismissal.

## Built-in scenes

Eight pure-Elisp scenes ship out of the box with zero external dependencies: `matrix` (digital rain), `snow` (drifting flakes), `plasma` (quantized interference field), `donut` (rotating 3D ASCII torus), `equalizer` (colorful spectrum bars with peaks and reflection), `sand` (falling grains), `poems` (warm-paper classical Chinese lines on a framed card) and `clock` (block-element digital clock with gentle drift).

## Customizing and authoring scenes

Configure per-scene options directly in `etaf-screensaver-playlist`, or define your own scenes in Emacs Lisp using the built-in builders (`etaf-screensaver-define-text-scene`, `etaf-screensaver-define-field-scene`, `etaf-screensaver-define-particle-scene`) or the general `etaf-screensaver-define-scene` macro with the public canvas and color toolkit:

```elisp
(etaf-screensaver-define-text-scene my-quotes
  :title "每日一言"
  :background "#F4F1EA"
  :frame 'card
  :style 'typewriter
  :items '((:text "山高月小，水落石出" :caption "苏轼 · 《后赤壁赋》")
           (:text "行到水穷处，坐看云起时" :caption "王维 · 《终南别业》")))
```

See the [manual](docs/manual.md) for configuration details and authoring recipes, [architecture](docs/architecture.md) for ownership and rendering invariants, and the [entry Commentary](etaf-screensaver.el) for the supported public API inventory.

## Development

```sh
make check              # structure, compilation, public acceptance and API checks
make gui SERVER=...     # maintained GUI scenario in an owned graphical Emacs server
```

From the enclosing workspace, measure autonomous frame cadence with:

```sh
python3 scripts/performance.py run --mode batch \
  --scenario-file apps/etaf-screensaver/benchmarks/performance-scenarios.el \
  --load-path apps/etaf-screensaver --scenario 'etaf-screensaver.frame.*'
```

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
